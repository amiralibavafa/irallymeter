// Unit tests for the AVERAGE SPEED calculation logic.
//
// Target: [AverageSpeedCalculator] — the pure (plugin-free) integrator that a
// professional rally trip meter's average readout is built on:
//
//     average speed = accumulated ground distance ÷ accumulated travel time
//
// Behaviour under test (mirrors the trip computer's reliability rules):
//   • time accrues for every accepted, in-window pair of fixes…
//   • …but distance only accrues for real movement (≥ 1 m steps), so a stop
//     freezes the distance while time keeps ticking → the average decays.
//   • GPS dropouts and physically impossible teleports are excluded entirely.
//   • invalid / no data never produces a divide-by-zero or a phantom average.

import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/features/average_speed/domain/average_speed_calculator.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';

void main() {
  group('AVERAGE SPEED · AverageSpeedCalculator', () {
    test('01 · no GPS data → average is a clean 0 (no divide-by-zero)', () {
      final c = AverageSpeedCalculator();
      expect(c.averageMps, 0);
      expect(c.distanceMeters, 0);
      expect(c.elapsed, Duration.zero);
    });

    test('02 · a single fix only anchors — no distance or time yet', () {
      final c = AverageSpeedCalculator()..add(_fix(lat: 46.0, lon: 8.0, tMs: 0));
      expect(c.averageMps, 0);
      expect(c.elapsed, Duration.zero);
    });

    test('03 · constant speed over equal intervals → average ≈ that speed', () {
      // Two ~111.2 m steps, 2 s apart each → 222.4 m / 4 s ≈ 55.6 m/s.
      final c = AverageSpeedCalculator()
        ..add(_fix(lat: 46.000, lon: 8.0, tMs: 0))
        ..add(_fix(lat: 46.001, lon: 8.0, tMs: 2000))
        ..add(_fix(lat: 46.002, lon: 8.0, tMs: 4000));
      expect(c.distanceMeters, closeTo(222.4, 3));
      expect(c.elapsed, const Duration(seconds: 4));
      expect(c.averageMps, closeTo(55.6, 1));
    });

    test('04 · stationary the whole time → average stays 0 (distance frozen)',
        () {
      final c = AverageSpeedCalculator()
        ..add(_fix(lat: 46.0, lon: 8.0, tMs: 0))
        ..add(_fix(lat: 46.0, lon: 8.0, tMs: 2000))
        ..add(_fix(lat: 46.0, lon: 8.0, tMs: 4000));
      expect(c.distanceMeters, 0);
      expect(c.elapsed, const Duration(seconds: 4)); // time still accrues
      expect(c.averageMps, 0);
    });

    test('05 · stopping after moving pulls the running average down', () {
      final c = AverageSpeedCalculator()
        // Move: 222.4 m in 4 s (≈ 55.6 m/s).
        ..add(_fix(lat: 46.000, lon: 8.0, tMs: 0))
        ..add(_fix(lat: 46.001, lon: 8.0, tMs: 2000))
        ..add(_fix(lat: 46.002, lon: 8.0, tMs: 4000));
      final movingAvg = c.averageMps;
      // Then sit still for 6 s (3 × 2 s fixes, same position).
      c
        ..add(_fix(lat: 46.002, lon: 8.0, tMs: 6000))
        ..add(_fix(lat: 46.002, lon: 8.0, tMs: 8000))
        ..add(_fix(lat: 46.002, lon: 8.0, tMs: 10000));
      expect(c.distanceMeters, closeTo(222.4, 3)); // distance unchanged
      expect(c.elapsed, const Duration(seconds: 10)); // 4 s moving + 6 s stopped
      expect(c.averageMps, lessThan(movingAvg));
      expect(c.averageMps, closeTo(222.4 / 10, 0.5)); // ≈ 22.2 m/s
    });

    test('06 · a change in speed yields an average between the two', () {
      // Fast: 111.2 m in 2 s (≈ 55.6 m/s). Slow: 55.6 m in 5 s (≈ 11.1 m/s).
      final c = AverageSpeedCalculator()
        ..add(_fix(lat: 46.0000, lon: 8.0, tMs: 0))
        ..add(_fix(lat: 46.0010, lon: 8.0, tMs: 2000))
        ..add(_fix(lat: 46.0015, lon: 8.0, tMs: 7000));
      expect(c.averageMps, greaterThan(11.1));
      expect(c.averageMps, lessThan(55.6));
      expect(c.averageMps, closeTo(166.8 / 7, 1.5)); // ≈ 23.8 m/s
    });

    test('07 · varying update intervals still give distance ÷ total time', () {
      // Steps of 1 s, 3 s and 2 s at a steady ~25 m/s; 150 m over 6 s.
      //
      // DATA CHANGED in [3.4d], with Saam's sign-off, and the assertions moved
      // with it. The original drove 111.2 m in 2 s straight after 55.6 m in
      // 3 s — a car going 67 to 200 km/h in two seconds, roughly 2 g, and
      // exactly 3x the displacement its previous speed predicted. SPEC-v2 §6.1
      // rule 4 rejects precisely that, so the fixture and the spec could not
      // both stand. The test's PURPOSE is unchanged: uneven update intervals
      // must still integrate to distance / total time.
      final c = AverageSpeedCalculator()
        ..add(_fix(lat: 46.0000, lon: 8.0, speed: 25, tMs: 0))
        ..add(_fix(lat: 46.000225, lon: 8.0, speed: 25, tMs: 1000)) // 25 m / 1 s
        ..add(_fix(lat: 46.000900, lon: 8.0, speed: 25, tMs: 4000)) // 75 m / 3 s
        ..add(_fix(lat: 46.001350, lon: 8.0, speed: 25, tMs: 6000)); // 50 m / 2 s
      expect(c.distanceMeters, closeTo(150, 3));
      expect(c.elapsed, const Duration(seconds: 6));
      expect(c.averageMps, closeTo(25, 1.5));
    });

    test('08 · reset() clears the leg; integration restarts cleanly', () {
      final c = AverageSpeedCalculator()
        ..add(_fix(lat: 46.000, lon: 8.0, tMs: 0))
        ..add(_fix(lat: 46.001, lon: 8.0, tMs: 2000));
      expect(c.averageMps, greaterThan(0));

      c.reset();
      expect(c.averageMps, 0);
      expect(c.distanceMeters, 0);
      expect(c.elapsed, Duration.zero);

      // New leg accumulates from scratch.
      c
        ..add(_fix(lat: 46.000, lon: 8.0, tMs: 10000)) // re-anchor
        ..add(_fix(lat: 46.001, lon: 8.0, tMs: 12000));
      expect(c.averageMps, closeTo(55.6, 1));
    });

    test('09 · long-distance travel averages correctly', () {
      // 15 × ~222 m steps at a realistic 5 s cadence → ~3336 m / 75 s ≈ 44.5 m/s.
      // (Fix intervals stay inside the dropout window, as real GPS does.)
      final c = AverageSpeedCalculator();
      for (var i = 0; i <= 15; i++) {
        c.add(_fix(lat: 46.0 + i * 0.002, lon: 8.0, tMs: i * 5000));
      }
      expect(c.distanceMeters, greaterThan(3000));
      expect(c.elapsed, const Duration(seconds: 75));
      expect(c.averageMps, closeTo(44.5, 1));
    });

    test('10 · zero elapsed time (same timestamp) → average 0, no NaN', () {
      final c = AverageSpeedCalculator()
        ..add(_fix(lat: 46.000, lon: 8.0, tMs: 1000))
        ..add(_fix(lat: 46.001, lon: 8.0, tMs: 1000)); // dt = 0 → re-anchor
      expect(c.elapsed, Duration.zero);
      expect(c.averageMps, 0);
      expect(c.averageMps.isNaN, isFalse);
    });

    test('11 · invalid accuracy fixes are ignored entirely', () {
      final c = AverageSpeedCalculator()
        ..add(_fix(lat: 46.000, lon: 8.0, tMs: 0, acc: 0)) // no fix quality
        ..add(_fix(lat: 46.001, lon: 8.0, tMs: 2000, acc: 999)); // way over usable
      expect(c.distanceMeters, 0);
      expect(c.elapsed, Duration.zero);
      expect(c.averageMps, 0);
    });

    test('12 · physically impossible teleport adds no distance or time', () {
      final c = AverageSpeedCalculator()
        ..add(_fix(lat: 46.00, lon: 8.0, tMs: 0))
        // ~1113 m in 1 s ≈ 1113 m/s → a bad fix, excluded.
        ..add(_fix(lat: 46.01, lon: 8.0, tMs: 1000));
      expect(c.distanceMeters, 0);
      expect(c.elapsed, Duration.zero);
      expect(c.averageMps, 0);
    });

    test('13 · out-of-order (negative dt) fixes are skipped', () {
      final c = AverageSpeedCalculator()
        ..add(_fix(lat: 46.000, lon: 8.0, tMs: 5000))
        ..add(_fix(lat: 46.001, lon: 8.0, tMs: 2000)); // earlier than anchor
      expect(c.elapsed, Duration.zero);
      expect(c.averageMps, 0);
    });

    test('14 · a GPS dropout gap is excluded from elapsed time', () {
      // gpsStaleTimeout is 3 s; gaps > 9 s re-anchor instead of integrating.
      final c = AverageSpeedCalculator()
        ..add(_fix(lat: 46.000, lon: 8.0, tMs: 0))
        ..add(_fix(lat: 46.001, lon: 8.0, tMs: 20000)) // 20 s gap → excluded
        ..add(_fix(lat: 46.002, lon: 8.0, tMs: 22000)); // 2 s, ~111 m → counted
      expect(c.elapsed, const Duration(seconds: 2)); // gap NOT counted
      expect(c.distanceMeters, closeTo(111.2, 2));
      expect(c.averageMps, closeTo(55.6, 1));
    });

    test('15 · standstill jitter adds time but no phantom distance', () {
      // ~0.44 m wander (under the 1 m floor) over 2 s.
      final c = AverageSpeedCalculator()
        ..add(_fix(lat: 46.000000, lon: 8.0, tMs: 0))
        ..add(_fix(lat: 46.000004, lon: 8.0, tMs: 2000));
      expect(c.distanceMeters, 0); // jitter rejected
      expect(c.elapsed, const Duration(seconds: 2)); // but time still counts
      expect(c.averageMps, 0);
    });
  });
}

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
