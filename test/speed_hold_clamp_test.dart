import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/core/constants/app_constants.dart';
import 'package:irallymeter/features/distance/domain/longitudinal_axis_estimator.dart';
import 'package:irallymeter/features/distance/domain/motion_sample.dart';
import 'package:irallymeter/features/distance/domain/sensor_distance_source.dart';

/// SPEC-v2 §12.2 — how far the accelerometer may move the held speed.
///
/// "Clamp the total adjustment to ±25% of v₀. If the correction wants to
/// exceed this, ignore it and hold v₀."
///
/// Applied UPWARDS only; see the deviation note on [SensorDistanceSource].
DateTime t(int ms) => DateTime.utc(2026).add(Duration(milliseconds: ms));

MotionSample motion({required int ms, double ax = 0, double gz = 0}) =>
    MotionSample(
      timestamp: t(ms),
      userAccel: Vec3(ax, 0, 0),
      gravity: const Vec3(0, 0, 9.81),
      gyro: Vec3(0, 0, gz),
    );

/// An axis estimator trained until it confidently points forward along +x.
LongitudinalAxisEstimator confidentAxis() {
  final a = LongitudinalAxisEstimator();
  for (var i = 0; i < 40; i++) {
    a.observe(motion(ms: i * 100, ax: 2.0), 2.0);
  }
  expect(a.isConfident, isTrue, reason: 'harness precondition');
  return a;
}

void main() {
  group('§12.2 · the ±25% bound', () {
    test('01 · the fraction is 25%, as the spec states', () {
      expect(AppConstants.maxSpeedAdjustFraction, 0.25);
    });

    test('02 · sustained acceleration cannot push speed past v₀ + 25%', () {
      final s = SensorDistanceSource(confidentAxis())..seed(20, t(0));
      for (var ms = 250; ms <= 60000; ms += 250) {
        final d = s.add(motion(ms: ms, ax: 500))!; // absurd, sustained
        expect(d.speedMps, lessThanOrEqualTo(25.0 + 1e-9),
            reason: 'v₀ = 20 m/s, so the ceiling is 25 m/s — NOT the 30 m/s '
                'the previous max(v*1.5, v+8) cap allowed');
      }
    });

    test('03 · the old cap allowed 30 m/s here; the spec allows 25', () {
      // The change this step exists to make, stated as a number.
      final s = SensorDistanceSource(confidentAxis())..seed(20, t(0));
      for (var ms = 250; ms <= 30000; ms += 250) {
        s.add(motion(ms: ms, ax: 100));
      }
      expect(s.speedMps, closeTo(25.0, 1e-6));
      expect(s.speedMps, lessThan(30.0));
    });

    test('04 · the bound is on TOTAL drift, not per sample', () {
      // Many small, individually plausible nudges must not walk the estimate
      // somewhere a single large step would have been refused.
      final s = SensorDistanceSource(confidentAxis())..seed(40, t(0));
      for (var ms = 250; ms <= 120000; ms += 250) {
        s.add(motion(ms: ms, ax: 0.3)); // gentle, well inside the accel clamp
      }
      expect(s.speedMps, lessThanOrEqualTo(50.0 + 1e-9),
          reason: 'v₀ = 40 m/s → ceiling 50 m/s, however long the nudging runs');
    });

    test('05 · a 0 m/s entry stays at 0 — nothing to anchor a refinement to',
        () {
      final s = SensorDistanceSource(confidentAxis())..seed(0, t(0));
      for (var ms = 250; ms <= 10000; ms += 250) {
        final d = s.add(motion(ms: ms, ax: 3.0))!;
        expect(d.speedMps, 0.0);
        expect(d.meters, 0.0);
      }
    });
  });

  group('§12.2 · the deliberate downward deviation', () {
    test('06 · braking may run all the way to a stop, past −25%', () {
      // A symmetric band would hold this at v₀ = 20 m/s and invent distance for
      // as long as the car sat there. Over-estimates are permanent — the engine
      // reconciles undershoot only — so the bound is applied upwards only.
      final s = SensorDistanceSource(confidentAxis())..seed(20, t(0));
      for (var ms = 250; ms <= 20000; ms += 250) {
        final d = s.add(motion(ms: ms, ax: -30))!;
        expect(d.speedMps, greaterThanOrEqualTo(0));
      }
      expect(s.speedMps, 0.0,
          reason: 'a detected stop must be believed; refusing to is not '
              'caution, it is a worse estimate');
    });

    test('07 · a stopped estimate stops accumulating distance', () {
      final s = SensorDistanceSource(confidentAxis())..seed(20, t(0));
      for (var ms = 250; ms <= 20000; ms += 250) {
        s.add(motion(ms: ms, ax: -30));
      }
      var afterStop = 0.0;
      for (var ms = 20250; ms <= 40000; ms += 250) {
        afterStop += s.add(motion(ms: ms))!.meters;
      }
      expect(afterStop, 0.0,
          reason: 'this is the whole point of allowing the downward run');
    });
  });

  group('§12.1 · the model underneath', () {
    test('08 · with no usable acceleration it coasts at exactly v₀', () {
      // "freeze the last valid speed v₀, accumulate v₀ × Δt".
      final s = SensorDistanceSource(LongitudinalAxisEstimator())
        ..seed(25, t(0));
      var total = 0.0;
      for (var ms = 250; ms <= 10000; ms += 250) {
        total += s.add(motion(ms: ms, ax: 2.0))!.meters;
      }
      expect(s.speedMps, closeTo(25.0, 1e-9),
          reason: 'an unlearned axis means the sign is unknown, so coast');
      expect(total, closeTo(25.0 * 10.0, 0.5));
    });
  });
}
