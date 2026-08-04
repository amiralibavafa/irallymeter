// THE RECONNECT LOOP — the thing that was never tested and never worked.
//
// Codex's adversarial pass on the background location lifecycle found that
// `yield*` forwards a stream's ERROR EVENTS to the consumer rather than
// throwing them into the enclosing `try/catch`. So the whole retry/downgrade
// block in `GeolocatorGpsService.positionStream` was unreachable: one error
// ended the stream permanently for the rest of the process.
//
// That is the observed Android OFF -> ON failure (`ROAD-TEST` item 1), and it
// is also why `[SA-V2 8]`'s two-consecutive-errors rule had no effect — it
// lived in dead code. The old tests could not have caught it: they exercised
// `GpsStallDetector` in isolation, which is the one piece that was fine.
//
// These drive the LOOP, through the injected seam.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:irallymeter/features/gps/data/geolocator_gps_service.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';

Position _pos(int i) => Position(
      latitude: 35.7 + i * 0.0001,
      longitude: 51.4,
      timestamp: DateTime.utc(2026).add(Duration(seconds: i)),
      accuracy: 5,
      altitude: 1200,
      altitudeAccuracy: 3,
      heading: 0,
      headingAccuracy: 5,
      speed: 20,
      speedAccuracy: 0.5,
    );

void main() {
  group('RECONNECT · the retry controller must actually run', () {
    test('01 · a stream error is retried, not fatal', () async {
      // The regression. Before the rewrite this yielded one sample and then
      // ended forever, because the error reached the consumer instead of the
      // catch block.
      var attempts = 0;
      final svc = GeolocatorGpsService(
        positionSource: (_) {
          attempts++;
          if (attempts == 1) {
            return Stream<Position>.error(Exception('platform boom'));
          }
          return Stream<Position>.value(_pos(attempts));
        },
        serviceEnabled: () async => true,
      );

      final seen = <GpsSample>[];
      final sub = svc.positionStream().listen(seen.add);
      await Future<void>.delayed(const Duration(seconds: 4));
      await sub.cancel();

      expect(attempts, greaterThanOrEqualTo(2),
          reason: 'the loop never re-subscribed after an error — this is the '
              'exact failure that made OFF->ON unrecoverable');
      expect(seen.any((s) => s.hasFix), isTrue,
          reason: 'a real fix must arrive after the retry');
    });

    test('02 · the consumer never sees the error itself', () async {
      // The stream must stay alive for its listener. If the error escapes, the
      // dashboard's subscription dies and the trip counter freezes.
      var attempts = 0;
      final svc = GeolocatorGpsService(
        positionSource: (_) {
          attempts++;
          if (attempts <= 2) {
            return Stream<Position>.error(Exception('boom $attempts'));
          }
          return Stream<Position>.value(_pos(attempts));
        },
        serviceEnabled: () async => true,
      );

      Object? escaped;
      final sub = svc.positionStream().listen((_) {}, onError: (Object e) {
        escaped = e;
      });
      await Future<void>.delayed(const Duration(seconds: 4));
      await sub.cancel();

      expect(escaped, isNull,
          reason: 'an error reaching the listener kills the dashboard '
              'subscription for the rest of the drive');
    });

    test('03 · a no-fix heartbeat is emitted so the UI can show the gap',
        () async {
      var attempts = 0;
      final svc = GeolocatorGpsService(
        positionSource: (_) {
          attempts++;
          if (attempts == 1) {
            return Stream<Position>.error(Exception('boom'));
          }
          return Stream<Position>.value(_pos(attempts));
        },
        serviceEnabled: () async => true,
      );

      final seen = <GpsSample>[];
      final sub = svc.positionStream().listen(seen.add);
      await Future<void>.delayed(const Duration(seconds: 4));
      await sub.cancel();

      expect(seen.any((s) => !s.hasFix), isTrue,
          reason: 'the status bar must be told there is a gap rather than '
              'holding a stale value');
    });

    test('04 · ONE transient error keeps the foreground service', () async {
      // `[SA-V2 8]`'s rule, now on a code path that runs. The foreground
      // service is what keeps the receiver alive with the screen off, so one
      // hiccup must not cost it for the rest of the drive.
      final backgroundFlags = <bool>[];
      var attempts = 0;
      final svc = GeolocatorGpsService(
        positionSource: (settings) {
          attempts++;
          backgroundFlags.add(_wantsBackground(settings));
          if (attempts == 1) {
            return Stream<Position>.error(Exception('one-off'));
          }
          return Stream<Position>.value(_pos(attempts));
        },
        serviceEnabled: () async => true,
      );

      final sub = svc.positionStream().listen((_) {});
      await Future<void>.delayed(const Duration(seconds: 4));
      await sub.cancel();

      expect(backgroundFlags.length, greaterThanOrEqualTo(2));
      expect(backgroundFlags[1], isTrue,
          reason: 'a single transient error downgraded background tracking');
    });

    test('05 · TWO consecutive errors do downgrade it', () async {
      // The case the fallback exists for: POST_NOTIFICATIONS denied, so the
      // foreground service fails every time. It must still give up.
      final backgroundFlags = <bool>[];
      var attempts = 0;
      final svc = GeolocatorGpsService(
        positionSource: (settings) {
          attempts++;
          backgroundFlags.add(_wantsBackground(settings));
          if (attempts <= 2) {
            return Stream<Position>.error(Exception('fgs refused'));
          }
          return Stream<Position>.value(_pos(attempts));
        },
        serviceEnabled: () async => true,
      );

      final sub = svc.positionStream().listen((_) {});
      await Future<void>.delayed(const Duration(seconds: 6));
      await sub.cancel();

      expect(backgroundFlags.length, greaterThanOrEqualTo(3));
      expect(backgroundFlags[2], isFalse,
          reason: 'two consecutive failures must fall back to '
              'foreground-only, or a device with notifications denied never '
              'gets a working stream at all');
    });

    test('06 · cancelling the consumer stops re-subscribing', () async {
      // Otherwise the loop spins forever after the dashboard goes away, holding
      // the foreground service open and draining the battery.
      var attempts = 0;
      final svc = GeolocatorGpsService(
        positionSource: (_) {
          attempts++;
          return Stream<Position>.error(Exception('always fails'));
        },
        serviceEnabled: () async => true,
      );

      final sub = svc.positionStream().listen((_) {});
      await Future<void>.delayed(const Duration(seconds: 4));
      await sub.cancel();

      // Let any cycle that was already in flight finish, then prove the count
      // has STOPPED MOVING. Asserting zero further subscriptions would be
      // wrong, not merely strict: cancellation reaches an `async*` generator at
      // its next suspension point, so a cycle already inside the reconnect
      // backoff completes by design. What must never happen is the count
      // continuing to climb, which is the battery-draining spin.
      await Future<void>.delayed(const Duration(seconds: 3));
      final settled = attempts;
      await Future<void>.delayed(const Duration(seconds: 4));

      expect(attempts, settled,
          reason: 'the loop was still re-subscribing $settled -> $attempts '
              'after its listener was gone — it never stops, and the '
              'foreground service stays up draining the battery');
    });
  });
}

/// Whether these settings asked for background updates, across both platform
/// shapes `buildSettings` can return.
bool _wantsBackground(LocationSettings s) {
  if (s is AndroidSettings) return s.foregroundNotificationConfig != null;
  if (s is AppleSettings) return s.allowBackgroundLocationUpdates;
  return false;
}
