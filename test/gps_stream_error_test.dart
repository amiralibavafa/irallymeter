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

    test('05 · an error DROPS the position baseline', () async {
      // A receiver reporting 0.0 for Doppler falls back to differentiating
      // POSITIONS (§7.1). If an error leaves the previous fix in place, the
      // first fix after recovery is differenced against a position from before
      // the outage — so a car that drove during the outage and then stopped
      // shows its AVERAGE SPEED OVER THE WHOLE GAP while stationary, and the
      // filter adopts it almost at once because the elapsed time is large.
      //
      // The old code emitted noFix() here, which replaced the baseline and made
      // this impossible by accident. Marking the error kept the sample out of
      // that path, so the guard had to become explicit. Codex, SA-V3.
      final c = StreamController<GpsSample>();
      final container = ProviderContainer(overrides: [
        gpsRepositoryProvider.overrideWithValue(_FakeGps(c.stream)),
      ]);
      final sub = container.listen(gpsStateProvider, (_, __) {},
          fireImmediately: true);

      // Stationary at the start line, no usable Doppler.
      c.add(_zeroDopplerFix(lat: 46.0, tMs: 0));
      await _pump();

      // The receiver fails. Meanwhile the car drives 2 km unobserved.
      c.add(GpsSample.error('permission revoked'));
      await _pump();

      // Recovery, 2 km away and STOPPED.
      c.add(_zeroDopplerFix(lat: 46.018, tMs: 120000));
      await _pump();
      final speed = container.read(gpsStateProvider).valueOrNull?.smoothedSpeedMps ?? -1;

      sub.close();
      container.dispose();

      expect(speed, lessThan(2.0),
          reason: 'the car is stationary, but the speed was derived across the '
              'whole outage against a pre-error position. A stopped rally car '
              'reading 16 m/s is worse than reading nothing');
    });

    test('06 · a DIRECT stream error drops the baseline too', () async {
      // TWO PATHS REACH "the stream failed" AND THE FIX ONLY COVERED ONE.
      // Test 05 emits a MARKED SAMPLE, which is what the real service produces.
      // This one emits a genuine AsyncError, which is what any other repository
      // produces — and that branch kept the stale baseline, so the same
      // 60 km/h-while-stationary reading was still reachable.
      //
      // Codex round 2 found it. Test 05 passing with this fix removed is
      // precisely why a second test is needed rather than a wider assertion.
      final c = StreamController<GpsSample>();
      final container = ProviderContainer(overrides: [
        gpsRepositoryProvider.overrideWithValue(_FakeGps(c.stream)),
      ]);
      final sub = container.listen(gpsStateProvider, (_, __) {},
          fireImmediately: true);

      c.add(_zeroDopplerFix(lat: 46.0, tMs: 0));
      await _pump();

      c.addError(Exception('platform failure'));
      await _pump();

      c.add(_zeroDopplerFix(lat: 46.018, tMs: 120000));
      await _pump();
      final speed = container.read(gpsStateProvider).valueOrNull?.smoothedSpeedMps ?? -1;

      sub.close();
      container.dispose();

      expect(speed, lessThan(2.0),
          reason: 'the car is stationary. The AsyncError path kept the '
              'pre-outage position as the differencing baseline');
    });

    test('07 · the SPEED FILTER is reset too, not just the baseline',
        () async {
      // A THIRD ROUTE TO THE SAME LIE, and clearing `prev` does not close it.
      //
      // Tests 05 and 06 use a TRUSTWORTHY zero Doppler, so with `prev` cleared
      // the positional fallback simply cannot run and the readout is 0. This
      // one uses an UNTRUSTWORTHY reading (NaN), which is what a struggling
      // receiver actually produces: `SpeedFilter.add` returns its RETAINED
      // value for a NaN sample, so the cluster kept showing the pre-outage
      // 20 m/s on a stationary car while reporting a valid fix.
      //
      // `SpeedFilter.reset()` already existed and simply had no caller on this
      // path — the same shape as C2's stall counter. Codex round 3.
      final c = StreamController<GpsSample>();
      final container = ProviderContainer(overrides: [
        gpsRepositoryProvider.overrideWithValue(_FakeGps(c.stream)),
      ]);
      final sub = container.listen(gpsStateProvider, (_, __) {},
          fireImmediately: true);

      // Moving at 20 m/s, trustworthy, so the filter charges up.
      for (var i = 0; i < 6; i++) {
        c.add(_movingFix(tMs: i * 1000));
        await _pump();
      }
      expect(container.read(gpsStateProvider).valueOrNull?.smoothedSpeedMps ?? 0,
          greaterThan(10),
          reason: 'precondition: the filter must actually be holding a speed');

      c.addError(Exception('platform failure'));
      await _pump();

      // Recovered, STOPPED, and the receiver reports an unusable speed.
      c.add(_nanDopplerFix(tMs: 200000));
      await _pump();
      final speed =
          container.read(gpsStateProvider).valueOrNull?.smoothedSpeedMps ?? -1;

      sub.close();
      container.dispose();

      expect(speed, lessThan(2.0),
          reason: 'the car is stationary. The filter handed back the speed it '
              'was holding from before the failure, because a NaN reading '
              'leaves its retained value untouched');
    });

    test('08 · a STALL invalidates too, though it is not an error', () async {
      // THE THIRD BREAK PATH. A stall carries no `errorMessage` — deliberately,
      // it is not a platform failure and must not raise GPS ERROR — so it
      // reached NEITHER error branch and left every derived value intact.
      // Round 4 found it after rounds 2 and 3 had patched the other two paths
      // one piece of state at a time.
      final c = StreamController<GpsSample>();
      final container = ProviderContainer(overrides: [
        gpsRepositoryProvider.overrideWithValue(_FakeGps(c.stream)),
      ]);
      final sub = container.listen(gpsStateProvider, (_, __) {},
          fireImmediately: true);

      for (var i = 0; i < 6; i++) {
        c.add(_movingFix(tMs: i * 1000));
        await _pump();
      }
      expect(container.read(gpsStateProvider).valueOrNull?.smoothedSpeedMps ?? 0,
          greaterThan(10), reason: 'precondition');

      c.add(GpsSample.stalled());
      await _pump();
      c.add(_nanDopplerFix(tMs: 200000));
      await _pump();
      final speed =
          container.read(gpsStateProvider).valueOrNull?.smoothedSpeedMps ?? -1;

      sub.close();
      container.dispose();

      expect(speed, lessThan(2.0),
          reason: 'a rebuilt subscription means driving happened unobserved, '
              'so the pre-stall speed is not evidence about the speed now');
    });

    test('09 · an outage also drops the HEADING, not just the speed',
        () async {
      // The fourth piece of derived state, and the last cell of the grid.
      // Republishing a pre-outage course as a current GPS heading is C1 again:
      // a confident bearing the receiver never reported.
      final c = StreamController<GpsSample>();
      final container = ProviderContainer(overrides: [
        gpsRepositoryProvider.overrideWithValue(_FakeGps(c.stream)),
      ]);
      final sub = container.listen(gpsStateProvider, (_, __) {},
          fireImmediately: true);

      for (var i = 0; i < 6; i++) {
        c.add(_movingFix(tMs: i * 1000));
        await _pump();
      }
      final before = container.read(gpsStateProvider).valueOrNull?.headingDeg;
      expect(before != null && before.isFinite, isTrue,
          reason: 'precondition: a heading must actually be held');

      c.addError(Exception('platform failure'));
      await _pump();

      // READ AFTER RECOVERY, NOT AFTER THE ERROR. Reading straight after the
      // error proves nothing: that branch publishes `GpsState.initial()`, whose
      // heading is NaN whatever the smoother is holding. The defect only shows
      // once a fix arrives and the smoother is consulted again. My first
      // version of this test made exactly that mistake and passed with the fix
      // removed.
      c.add(_noCourseFix(tMs: 200000));
      await _pump();
      final after = container.read(gpsStateProvider).valueOrNull?.headingDeg;

      sub.close();
      container.dispose();

      expect(after == null || after.isNaN, isTrue,
          reason: 'the cluster republished the pre-outage course as a live GPS '
              'heading, which is exactly the C1 failure again');
    });

    test('10 · a stream that COMPLETES invalidates too', () async {
      // THE QUIETEST BREAK PATH, and the last one found. A completed stream
      // emitted NOTHING and fell straight into the reconnect backoff, so the
      // consumer never learned the subscription had been replaced and the first
      // recovered fix reused the pre-outage speed. Codex round 5.
      final c = StreamController<GpsSample>();
      final container = ProviderContainer(overrides: [
        gpsRepositoryProvider.overrideWithValue(_FakeGps(c.stream)),
      ]);
      final sub = container.listen(gpsStateProvider, (_, __) {},
          fireImmediately: true);

      for (var i = 0; i < 6; i++) {
        c.add(_movingFix(tMs: i * 1000));
        await _pump();
      }
      expect(container.read(gpsStateProvider).valueOrNull?.smoothedSpeedMps ?? 0,
          greaterThan(10), reason: 'precondition');

      // What the service now emits when its inner stream completes.
      c.add(GpsSample.resubscribed());
      await _pump();
      c.add(_nanDopplerFix(tMs: 200000));
      await _pump();
      final speed =
          container.read(gpsStateProvider).valueOrNull?.smoothedSpeedMps ?? -1;

      sub.close();
      container.dispose();

      expect(speed, lessThan(2.0),
          reason: 'a rebuilt subscription means driving may have gone '
              'unobserved, whether or not it was a stall');
    });

    test('11 · a tunnel heartbeat does NOT republish the old GPS course',
        () async {
      // C1 AGAIN, ON THE ORDINARY TUNNEL PATH. A no-fix heartbeat was run
      // through the whole pipeline: `usingGpsCourse` stayed latched and the
      // pre-tunnel course was republished as a live GPS heading for the entire
      // length of the tunnel — a bearing the receiver was not reporting,
      // asserted as current, which is exactly what C1 was raised for.
      //
      // The heartbeat is NOT a subscription reset; the sky is just missing. So
      // this is fixed by not feeding measurement state from a sample that
      // measured nothing, rather than by invalidating.
      final c = StreamController<GpsSample>();
      final container = ProviderContainer(overrides: [
        gpsRepositoryProvider.overrideWithValue(_FakeGps(c.stream)),
      ]);
      final sub = container.listen(gpsStateProvider, (_, __) {},
          fireImmediately: true);

      for (var i = 0; i < 6; i++) {
        c.add(_movingFix(tMs: i * 1000));
        await _pump();
      }
      final before = container.read(gpsStateProvider).valueOrNull?.headingDeg;
      expect(before != null && before.isFinite, isTrue,
          reason: 'precondition: a GPS course must actually be held');

      // Into a tunnel: the watchdog's 20 s heartbeats, subscription untouched.
      for (var i = 0; i < 5; i++) {
        c.add(GpsSample.noFix());
        await _pump();
      }
      final during = container.read(gpsStateProvider).valueOrNull?.headingDeg;

      sub.close();
      container.dispose();

      expect(during == null || during.isNaN, isTrue,
          reason: 'the cluster asserted a live GPS course through a tunnel. '
              'NaN is what capHeadingProvider reads to fall through to the '
              'magnetometer, which is the honest source when the receiver is '
              'telling us nothing');
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

/// A fix from a receiver that reports 0.0 for Doppler — the case that makes the
/// app differentiate positions, and therefore the case the baseline matters for.
GpsSample _zeroDopplerFix({required double lat, required int tMs}) => GpsSample(
      timestamp: DateTime.fromMillisecondsSinceEpoch(tMs),
      latitude: lat,
      longitude: 8.0,
      speedMps: 0,
      headingDeg: double.nan,
      accuracyM: 5,
      altitudeM: 0,
      hasFix: true,
    );

GpsSample _movingFix({required int tMs}) => GpsSample(
      timestamp: DateTime.fromMillisecondsSinceEpoch(tMs),
      latitude: 46.0 + tMs / 1000 * 0.00018,
      longitude: 8.0,
      speedMps: 20,
      speedAccuracyMps: 0.5,
      headingDeg: 0,
      accuracyM: 5,
      altitudeM: 0,
      hasFix: true,
    );

/// A receiver that has a fix but cannot qualify its speed. `SpeedFilter.add`
/// returns its RETAINED value for this, which is the whole point of the test.
GpsSample _nanDopplerFix({required int tMs}) => GpsSample(
      timestamp: DateTime.fromMillisecondsSinceEpoch(tMs),
      latitude: 46.2,
      longitude: 8.0,
      speedMps: double.nan,
      headingDeg: double.nan,
      accuracyM: 5,
      altitudeM: 0,
      hasFix: true,
    );

/// Moving fast enough to select the GPS-course branch, but the receiver
/// reports NO course — so whatever the smoother holds is what gets published.
GpsSample _noCourseFix({required int tMs}) => GpsSample(
      timestamp: DateTime.fromMillisecondsSinceEpoch(tMs),
      latitude: 46.2,
      longitude: 8.0,
      speedMps: 20,
      speedAccuracyMps: 0.5,
      headingDeg: double.nan,
      accuracyM: 5,
      altitudeM: 0,
      hasFix: true,
    );

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
