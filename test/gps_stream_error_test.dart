// C14 (correctness core) — a FAILED stream must not read the same as a quiet one.
//
// Every consumer in the app used `.valueOrNull`, which turns an AsyncError into
// null. `gpsStateProvider` therefore SKIPPED stream errors entirely: a revoked
// permission mid-drive, a dead sensor and a platform exception were all silently
// dropped, and the cluster kept showing its last good value until the dropout
// watchdog eventually said GPS LOST.
//
// So a `0` meaning "the receiver is broken" looked exactly like a `0` meaning
// "the car is stopped", and GPS LOST — the label for a tunnel — was also the
// label for a permission the user had just revoked. One of those is waited out;
// the other needs the crew to do something.
//
// Only the CORRECTNESS core is fixed here. The per-screen empty/error design is
// six screens of UI decisions and is Saam's to choose, so it stays in the
// Stage 5 proposal.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:geolocator/geolocator.dart';
import 'package:irallymeter/features/gps/data/geolocator_gps_service.dart';
import 'package:irallymeter/features/gps/domain/gps_repository.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';

void main() {
  group('C14 · stream failures are distinguishable from silence', () {
    test('01 · a stream error is SURFACED, not swallowed', () async {
      // THE REGRESSION. Before the fix this stayed null forever.
      final c = StreamController<GpsSample>();
      final container = ProviderContainer(overrides: [
        gpsRepositoryProvider.overrideWithValue(_FakeGps(c.stream)),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(gpsStateProvider, (_, __) {},
          fireImmediately: true);
      addTearDown(sub.close);

      c.addError(Exception('permission revoked'));
      await _pump();

      expect(container.read(gpsStreamErrorProvider), isNotNull,
          reason: 'the failure was dropped by .valueOrNull, so a revoked '
              'permission was indistinguishable from a tunnel');
      expect(container.read(gpsStreamErrorProvider), contains('revoked'));
    });

    test('02 · a good fix CLEARS the error', () async {
      // Otherwise the cluster would keep crying GPS ERROR after recovery, which
      // is the same class of lie in the other direction.
      final c = StreamController<GpsSample>();
      final container = ProviderContainer(overrides: [
        gpsRepositoryProvider.overrideWithValue(_FakeGps(c.stream)),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(gpsStateProvider, (_, __) {},
          fireImmediately: true);
      addTearDown(sub.close);

      c.addError(Exception('boom'));
      await _pump();
      expect(container.read(gpsStreamErrorProvider), isNotNull);

      c.add(_fix());
      await _pump();

      expect(container.read(gpsStreamErrorProvider), isNull,
          reason: 'a fix arrived, so whatever was wrong is over');
    });

    test('03 · a TUNNEL is not an error', () async {
      // The distinction that matters. Silence is expected; it must keep
      // reading GPS LOST rather than GPS ERROR, or the label stops meaning
      // anything on a route with tunnels.
      final c = StreamController<GpsSample>();
      final container = ProviderContainer(overrides: [
        gpsRepositoryProvider.overrideWithValue(_FakeGps(c.stream)),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(gpsStateProvider, (_, __) {},
          fireImmediately: true);
      addTearDown(sub.close);

      c.add(_fix());
      await _pump();
      for (var i = 0; i < 10; i++) {
        c.add(GpsSample.noFix());
        await _pump();
      }

      expect(container.read(gpsStreamErrorProvider), isNull,
          reason: 'driving into a tunnel raised GPS ERROR. A tunnel is '
              'silence, and telling the crew the receiver is broken every time '
              'they go under a mountain makes the warning worthless');
    });

    test('04 · an error from the REAL service reaches the error UI', () async {
      // TESTS 01-03 ALL PASS AND STILL MISS THE PRODUCTION PATH. They inject a
      // fake repository that puts an error straight onto the stream, so they
      // prove the PROVIDER handles one — they never prove the provider is ever
      // GIVEN one.
      //
      // It was not. `GeolocatorGpsService.positionStream` catches every platform
      // error in its retry loop and yields `GpsSample.noFix()`, which is the
      // exact same value a tunnel produces. So in the shipped app the error
      // branch above was unreachable: a revoked permission, a dead sensor and a
      // platform exception all read as GPS LOST, and the crew was sent looking
      // for sky instead of into the settings screen.
      //
      // This drives the real service, so it fails if the loop ever goes back to
      // swallowing errors — which is the failure mode a fake repository cannot
      // see by construction.
      final svc = GeolocatorGpsService(
        positionSource: (_) =>
            Stream<Position>.error(Exception('permission revoked')),
        serviceEnabled: () async => true,
        lastKnownSource: ({required bool forceAndroidLocationManager}) async =>
            null,
      );
      final container = ProviderContainer(overrides: [
        gpsRepositoryProvider.overrideWithValue(svc),
      ]);
      final sub = container.listen(gpsStateProvider, (_, __) {},
          fireImmediately: true);

      // Real wall clock, not a pump: the service awaits `lastKnown()` and the
      // platform stream before its first error can surface.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final error = container.read(gpsStreamErrorProvider);

      // Torn down INSIDE the body, before the assertion. The retry loop
      // re-subscribes on a 1.5 s backoff and would outlive an addTearDown.
      sub.close();
      container.dispose();

      expect(error, isNotNull,
          reason: 'the retry loop converted the platform error to a plain '
              'no-fix sample, so the C14 error state could never be reached in '
              'production no matter what went wrong with the receiver');
      expect(error, contains('revoked'));
    });
  });
}

Future<void> _pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

GpsSample _fix() => GpsSample(
      timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
      latitude: 46.0,
      longitude: 8.0,
      speedMps: 10,
      headingDeg: 90,
      accuracyM: 5,
      altitudeM: 0,
      hasFix: true,
    );

class _FakeGps implements GpsRepository {
  _FakeGps(this._stream);
  final Stream<GpsSample> _stream;

  @override
  Stream<GpsSample> positionStream() => _stream;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<GpsSample?> lastKnown() async => null;
}
