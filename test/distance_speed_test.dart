// 20 test cases proving the SPEED and DISTANCE pipelines work end to end.
//
// Coverage:
//   • Pure math — Formatters (speed/distance/trip), SpeedFilter, GeoMath,
//     Calibration.
//   • Live SPEED pipeline (gpsStateProvider) — including the position-delta
//     fallback used when a device/emulator reports no Doppler speed.
//   • Live DISTANCE pipeline (TripController) — accumulation from raw GPS
//     fixes plus the rally-grade reliability guards.
//
// The pipeline tests drive real Riverpod providers with a fake GPS repository,
// so they exercise the exact code that runs on a phone.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/utils/formatters.dart';
import 'package:irallymeter/core/utils/geo_math.dart';
import 'package:irallymeter/features/distance/domain/motion_repository.dart';
import 'package:irallymeter/features/distance/domain/motion_sample.dart';
import 'package:irallymeter/features/distance/presentation/providers/distance_providers.dart';
import 'package:irallymeter/features/gps/domain/gps_repository.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';
import 'package:irallymeter/features/gps/domain/gps_state.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';
import 'package:irallymeter/features/settings/presentation/providers/settings_providers.dart';
import 'package:irallymeter/features/trip/data/trip_repository.dart';
import 'package:irallymeter/features/trip/domain/calibration.dart';
import 'package:irallymeter/features/trip/domain/trip_state.dart';
import 'package:irallymeter/features/trip/presentation/providers/trip_providers.dart';

void main() {
  // ===========================================================================
  // SPEED — pure conversion + smoothing
  // ===========================================================================
  group('SPEED · conversion (Formatters)', () {
    test('01 · m/s → km/h, rounded to whole units', () {
      expect(Formatters.speed(10, SpeedUnit.kmh), 36); // 10 m/s = 36 km/h
      expect(Formatters.speed(27.78, SpeedUnit.kmh), 100); // ≈100 km/h
    });

    test('02 · m/s → mph, rounded to whole units', () {
      expect(Formatters.speed(10, SpeedUnit.mph), 22); // 10 m/s ≈ 22.37 mph
    });

    test('03 · rejects negative / NaN / zero → 0', () {
      expect(Formatters.speed(-5, SpeedUnit.kmh), 0);
      expect(Formatters.speed(double.nan, SpeedUnit.kmh), 0);
      expect(Formatters.speed(0, SpeedUnit.kmh), 0);
    });
  });

  group('SPEED · smoothing (SpeedFilter)', () {
    test('04 · floors sub-noise-floor speed to a clean 0', () {
      final f = SpeedFilter();
      expect(f.add(0.2, 4), 0); // below 0.4 m/s noise floor
    });

    test('05 · EMA moves toward the target (between old and new)', () {
      final f = SpeedFilter()..add(0, 4); // seed at 0
      final v = f.add(10, 4);
      expect(v, greaterThan(0));
      expect(v, lessThan(10));
    });

    test('06 · holds previous value on a bad (NaN/negative) reading', () {
      final f = SpeedFilter()..add(8, 4); // seed at 8
      expect(f.add(double.nan, 4), 8);
      expect(f.add(-3, 4), 8);
    });
  });

  // ===========================================================================
  // SPEED — live pipeline (gpsStateProvider), incl. position-delta fallback
  // ===========================================================================
  group('SPEED · live pipeline (gpsStateProvider)', () {
    test('07 · derives speed from position delta when device reports none',
        () async {
      // Emulator / chips with no Doppler speed report speedMps == 0.
      final r = await _runSpeedPipeline([
        _fix(lat: 46.0, lon: 8.0, speed: 0, tMs: 1000),
        // ~11.1 m north in 1 s ≈ 11.1 m/s ≈ 40 km/h
        _fix(lat: 46.0001, lon: 8.0, speed: 0, tMs: 2000),
      ]);
      expect(r.last.smoothedSpeedMps, greaterThan(0),
          reason: 'speed must be derived from movement when none is reported');
    });

    test('08 · prefers the device-reported Doppler speed when present',
        () async {
      final r = await _runSpeedPipeline([
        _fix(lat: 46.0, lon: 8.0, speed: 20, tMs: 1000), // stationary pin, 20 m/s
      ]);
      expect(r.last.smoothedSpeedMps, closeTo(20, 0.001));
    });

    test('09 · rejects an impossible teleport-derived speed (stays 0)',
        () async {
      final r = await _runSpeedPipeline([
        _fix(lat: 46.0, lon: 8.0, speed: 0, tMs: 1000),
        // ~1113 m in 1 s ≈ 1113 m/s → physically impossible, ignored.
        _fix(lat: 46.01, lon: 8.0, speed: 0, tMs: 2000),
      ]);
      expect(r.last.smoothedSpeedMps, 0);
    });
  });

  // ===========================================================================
  // DISTANCE — pure geodesy + formatting + calibration
  // ===========================================================================
  group('DISTANCE · geodesy (GeoMath)', () {
    test('10 · ~111 m per 0.001° of latitude', () {
      final d = GeoMath.distanceMeters(46.0, 8.0, 46.001, 8.0);
      expect(d, closeTo(111.2, 1.0));
    });

    test('11 · identical points → 0 m', () {
      expect(GeoMath.distanceMeters(46.0, 8.0, 46.0, 8.0), closeTo(0, 0.001));
    });

    test('12 · larger separation → larger distance', () {
      final near = GeoMath.distanceMeters(46.0, 8.0, 46.001, 8.0);
      final far = GeoMath.distanceMeters(46.0, 8.0, 46.010, 8.0);
      expect(far, greaterThan(near * 9)); // ~10× the latitude delta
    });
  });

  group('DISTANCE · formatting (Formatters)', () {
    test('13 · under 1 km shows whole metres', () {
      expect(Formatters.distance(847, metric: true), '847 m');
    });

    test('14 · 1 km and above shows km with 2 dp', () {
      expect(Formatters.distance(1234, metric: true), '1.23 km');
      expect(Formatters.distance(10000, metric: true), '10.00 km');
    });

    test('15 · trip readout is always 2 dp km', () {
      expect(Formatters.trip(1234, metric: true), '1.23');
      expect(Formatters.trip(0, metric: true), '0.00');
    });
  });

  group('DISTANCE · calibration', () {
    test('16 · factor maps measured distance onto the reference', () {
      // Meter read 9.9 km over a true 10.0 km.
      final f = Calibration.factorFromReference(
        measuredMeters: 9900,
        referenceMeters: 10000,
      );
      expect(f, closeTo(1.0101, 0.001));
      // Applying it brings 9900 m back up to ~10000 m.
      expect(9900 * f, closeTo(10000, 1));
    });

    test('17 · factor is clamped to the sane 0.80–1.20 band', () {
      final tooHigh =
          Calibration.factorFromReference(measuredMeters: 100, referenceMeters: 10000);
      final tooLow =
          Calibration.factorFromReference(measuredMeters: 10000, referenceMeters: 100);
      expect(tooHigh, lessThanOrEqualTo(1.20));
      expect(tooLow, greaterThanOrEqualTo(0.80));
    });
  });

  // ===========================================================================
  // DISTANCE — live pipeline (TripController integrating raw GPS fixes)
  // ===========================================================================
  group('DISTANCE · live pipeline (TripController)', () {
    test('18 · accumulates Trip A, Trip B and the odometer over moving fixes',
        () async {
      final state = await _runTrip([
        _fix(lat: 46.000, lon: 8.0, tMs: 0), // seeds the anchor
        _fix(lat: 46.001, lon: 8.0, tMs: 2000), // +~111 m  (55 m/s, OK)
        _fix(lat: 46.002, lon: 8.0, tMs: 4000), // +~111 m
      ]);
      expect(state.tripA, closeTo(222.4, 3));
      expect(state.tripB, closeTo(222.4, 3));
      expect(state.odometer, closeTo(222.4, 3));
    });

    test('19 · ignores standstill jitter below the minimum movement', () async {
      final state = await _runTrip([
        _fix(lat: 46.0, lon: 8.0, tMs: 0),
        // ~0.5 m wander — under the 1 m floor, must not creep the trip.
        _fix(lat: 46.0000045, lon: 8.0, tMs: 2000),
      ]);
      expect(state.tripA, 0);
      expect(state.odometer, 0);
    });

    test('20 · rejects an impossible teleport jump (no phantom distance)',
        () async {
      final state = await _runTrip([
        _fix(lat: 46.0, lon: 8.0, tMs: 0),
        // ~1113 m in 1 s ≈ 1113 m/s → a bad fix, not real movement.
        _fix(lat: 46.01, lon: 8.0, tMs: 1000),
      ]);
      expect(state.tripA, 0);
      expect(state.odometer, 0);
    });
  });
}

// =============================================================================
// Test helpers
// =============================================================================

/// Builds a GPS fix. Accuracy defaults to a healthy 4 m (well inside usable).
GpsSample _fix({
  required double lat,
  required double lon,
  double speed = 0,
  double acc = 4,
  required int tMs,
}) {
  return GpsSample(
    timestamp: DateTime.fromMillisecondsSinceEpoch(tMs),
    latitude: lat,
    longitude: lon,
    speedMps: speed,
    headingDeg: double.nan,
    accuracyM: acc,
    altitudeM: 0,
    hasFix: true,
  );
}

/// Lets the Riverpod stream plumbing flush queued microtasks/events.
Future<void> _pump([int times = 5]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Fake GPS source that replays a caller-controlled stream of fixes.
class _FakeGps implements GpsRepository {
  _FakeGps(this._stream);
  final Stream<GpsSample> _stream;

  @override
  Future<bool> ensurePermission() async => true;
  @override
  Stream<GpsSample> positionStream() => _stream;
  @override
  Future<GpsSample?> lastKnown() async => null;
}

/// Silent motion source. The trip computer now integrates via the distance
/// engine, which owns the sensor fallback — so these GPS-only tests stub the
/// sensors out, exactly as they stub out GPS. Emitting nothing keeps the engine
/// on its GPS path, which is what these tests are about.
class _SilentMotion implements MotionRepository {
  @override
  Stream<MotionSample> motionStream() => const Stream<MotionSample>.empty();
}

/// In-memory trip store so the integrator doesn't touch Hive in tests.
class _FakeTripRepo implements TripRepository {
  TripState stored;
  _FakeTripRepo([this.stored = TripState.zero]);

  @override
  TripState load() => stored;
  @override
  Future<void> save(TripState s) async => stored = s;
}

/// Feeds [fixes] through the real [gpsStateProvider] and returns the GpsState
/// values it emitted (in order).
Future<List<GpsState>> _runSpeedPipeline(List<GpsSample> fixes) async {
  final controller = StreamController<GpsSample>();
  final container = ProviderContainer(overrides: [
    gpsRepositoryProvider.overrideWithValue(_FakeGps(controller.stream)),
  ]);
  addTearDown(container.dispose);

  final emitted = <GpsState>[];
  final sub = container.listen<AsyncValue<GpsState>>(
    gpsStateProvider,
    (_, next) {
      final v = next.valueOrNull;
      if (v != null) emitted.add(v);
    },
    fireImmediately: true,
  );
  addTearDown(sub.close);

  for (final f in fixes) {
    controller.add(f);
    await _pump();
  }
  await controller.close();
  await _pump();
  return emitted;
}

/// Feeds [fixes] through the real [TripController] (calibration = 1.0) and
/// returns the resulting trip state.
Future<TripState> _runTrip(List<GpsSample> fixes) async {
  final controller = StreamController<GpsSample>();
  final container = ProviderContainer(overrides: [
    gpsRepositoryProvider.overrideWithValue(_FakeGps(controller.stream)),
    motionRepositoryProvider.overrideWithValue(_SilentMotion()),
    tripRepositoryProvider.overrideWithValue(_FakeTripRepo()),
    calibrationProvider.overrideWithValue(1.0),
  ]);
  addTearDown(container.dispose);

  // Keep the controller (and its rawGpsStreamProvider dependency) alive.
  final sub = container.listen(tripProvider, (_, __) {}, fireImmediately: true);
  addTearDown(sub.close);

  for (final f in fixes) {
    controller.add(f);
    await _pump();
  }
  await controller.close();
  await _pump();
  return container.read(tripProvider);
}
