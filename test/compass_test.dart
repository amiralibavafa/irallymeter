import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/core/constants/app_constants.dart';
import 'package:irallymeter/features/compass/domain/heading_calibration.dart';

/// The compass, reported from the road as "laggy, has a delay and isn't
/// accurate". Three separate causes; these cover the two that were fixed.
///
///  1. LAG — the needle used a fixed per-sample EMA weight, so its lag in
///     seconds was a property of the device's magnetometer rate. Same class of
///     bug as the speed display in [3.7].
///  2. ACCURACY — "Use true north" changed only a LABEL. No declination was
///     ever applied, so the cluster showed a magnetic reading and called it
///     TRUE. In Iran that is roughly 4.5–6° of quiet error.
///  3. (NOT fixed here) tilt compensation uses the raw accelerometer, which
///     includes vehicle acceleration, so "which way is down" is wrong exactly
///     when the car is cornering. Recorded in docs/PHASE4-AUDIT.md.
final t0 = DateTime.utc(2026);

void main() {
  group('lag · the needle settles in clock time, not in samples', () {
    /// Seconds for a step from 0° to [target] to settle within [tolDeg],
    /// sampled every [period].
    double? settleSeconds({
      required double target,
      required Duration period,
      double tolDeg = 5.0,
    }) {
      final s = AngleSmoother(AppConstants.headingSmoothingTau);
      var t = t0;
      for (var i = 0; i < 10; i++) {
        s.add(0, t);
        t = t.add(period);
      }
      final start = t;
      while (t.difference(start) <= const Duration(seconds: 30)) {
        final v = s.add(target, t);
        final err = (v - target).abs();
        if ((err < 180 ? err : 360 - err) <= tolDeg) {
          return t.difference(start).inMicroseconds / 1e6;
        }
        t = t.add(period);
      }
      return null;
    }

    test('01 · a 90° turn settles in about a second at 200 ms sampling', () {
      final s = settleSeconds(target: 90, period: const Duration(milliseconds: 200));
      expect(s, isNotNull);
      expect(s, lessThanOrEqualTo(1.5),
          reason: 'the old per-sample weight took ~2.7 s at this rate');
    });

    test('02 · a 5x faster magnetometer does not change the settling TIME', () {
      // This is the whole point of the fix. The same needle used to be roughly
      // five times slower on a 200 ms device than on a 40 ms one.
      final slow =
          settleSeconds(target: 90, period: const Duration(milliseconds: 200))!;
      final fast =
          settleSeconds(target: 90, period: const Duration(milliseconds: 40))!;
      expect((slow - fast).abs(), lessThan(0.5),
          reason: 'lag must be a property of the clock, not the sensor rate');
    });

    test('03 · it is still SMOOTHED — a single spike does not swing the needle',
        () {
      final s = AngleSmoother(AppConstants.headingSmoothingTau);
      var t = t0;
      for (var i = 0; i < 20; i++) {
        s.add(90, t);
        t = t.add(const Duration(milliseconds: 100));
      }
      final after = s.add(270, t); // one wild reading
      expect((after - 90).abs(), lessThan(45),
          reason: 'a magnetometer near a speaker throws single wild samples; '
              'the needle must not chase them');
    });

    test('04 · it wraps across 0/360 by the short way, not the long way', () {
      final s = AngleSmoother(AppConstants.headingSmoothingTau);
      var t = t0;
      for (var i = 0; i < 20; i++) {
        s.add(350, t);
        t = t.add(const Duration(milliseconds: 100));
      }
      // 350 -> 10 is +20°, not -340°.
      for (var i = 0; i < 20; i++) {
        t = t.add(const Duration(milliseconds: 100));
        s.add(10, t);
      }
      final v = s.value;
      final err = (v - 10).abs();
      expect(err < 180 ? err : 360 - err, lessThan(5),
          reason: 'settled at $v — a needle that spins the long way round is '
              'the classic compass bug');
    });

    test('05 · an out-of-order timestamp holds rather than jumping', () {
      final s = AngleSmoother(AppConstants.headingSmoothingTau);
      s.add(90, t0.add(const Duration(seconds: 5)));
      final held = s.add(270, t0); // clock went backwards
      expect(held, 90);
    });
  });

  group('accuracy · TRUE is earned, never asserted', () {
    HeadingCalibration trained({
      double declination = 5.0,
      int samples = 40,
      double speed = 20,
      double accuracy = 5,
    }) {
      final c = HeadingCalibration();
      for (var i = 0; i < samples; i++) {
        final mag = (i * 9.0) % 360.0;
        c.observe(
          gpsCourseDeg: (mag + declination) % 360.0,
          magneticDeg: mag,
          speedMps: speed,
          accuracyM: accuracy,
        );
      }
      return c;
    }

    test('06 · nothing learned means nothing corrected', () {
      final c = HeadingCalibration();
      expect(c.isLearned, isFalse);
      expect(c.toTrue(123.0), 123.0,
          reason: 'returning the input unchanged is the honest answer; the bug '
              'being fixed was labelling it TRUE anyway');
    });

    test('07 · it learns the declination from GPS course', () {
      final c = trained(declination: 5.0);
      expect(c.isLearned, isTrue);
      expect(c.offsetDeg, closeTo(5.0, 1.0));
      expect(c.toTrue(0.0), closeTo(5.0, 1.0));
    });

    test('08 · a westerly (negative) declination works too', () {
      expect(trained(declination: -7.0).offsetDeg, closeTo(-7.0, 1.0));
    });

    test('09 · it learns correctly across the 0/360 seam', () {
      // The failure this guards: averaging raw angles instead of differences
      // drags the mean halfway around the dial.
      final c = HeadingCalibration();
      for (var i = 0; i < 40; i++) {
        c.observe(
          gpsCourseDeg: 2.0, // true 002
          magneticDeg: 357.0, // magnetic 357  → offset +5
          speedMps: 20,
          accuracyM: 5,
        );
      }
      expect(c.offsetDeg, closeTo(5.0, 1.0));
    });

    test('10 · a crawling vehicle teaches it nothing', () {
      final c = HeadingCalibration();
      final used = c.observe(
        gpsCourseDeg: 100, magneticDeg: 0, speedMps: 1.0, accuracyM: 5);
      expect(used, isFalse);
      expect(c.samples, 0,
          reason: 'a course from a barely-moving vehicle is direction-of-noise');
    });

    test('11 · a poor fix teaches it nothing', () {
      final c = HeadingCalibration();
      expect(
        c.observe(
            gpsCourseDeg: 100, magneticDeg: 0, speedMps: 25, accuracyM: 40),
        isFalse,
      );
    });

    test('12 · NaN inputs are ignored rather than poisoning the offset', () {
      final c = trained();
      final before = c.offsetDeg;
      c.observe(
          gpsCourseDeg: double.nan,
          magneticDeg: 10,
          speedMps: 25,
          accuracyM: 5);
      c.observe(
          gpsCourseDeg: 10,
          magneticDeg: double.nan,
          speedMps: 25,
          accuracyM: 5);
      expect(c.offsetDeg, before);
    });

    test('13 · the threshold is a real bar, not a formality', () {
      final c = HeadingCalibration();
      for (var i = 0; i < AppConstants.headingCalibrationSamples - 1; i++) {
        c.observe(
            gpsCourseDeg: 5, magneticDeg: 0, speedMps: 20, accuracyM: 5);
      }
      expect(c.isLearned, isFalse, reason: 'one short of the bar');
      c.observe(gpsCourseDeg: 5, magneticDeg: 0, speedMps: 20, accuracyM: 5);
      expect(c.isLearned, isTrue);
    });

    test('14 · correcting a heading never produces an out-of-range angle', () {
      final c = trained(declination: 8.0);
      for (final mag in [0.0, 90.0, 179.9, 180.0, 355.0, 359.9]) {
        final t = c.toTrue(mag);
        expect(t, greaterThanOrEqualTo(0.0));
        expect(t, lessThan(360.0));
      }
    });
  });
}
