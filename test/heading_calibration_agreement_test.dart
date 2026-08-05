// C5 — "agreeing samples" were never checked for agreement.
//
// `HeadingCalibration`'s own doc says it reports [isLearned] false "until it
// has enough agreeing samples". The implementation was a bare count:
//
//     bool get isLearned => _samples >= AppConstants.headingCalibrationSamples;
//
// Twenty mutually contradictory observations cleared that bar exactly as
// readily as twenty consistent ones. There was no residual, no variance and no
// outlier gate anywhere in the class.
//
// This is not a theoretical worry. Hard-iron distortion from a magnetic phone
// mount is HEADING-DEPENDENT: the error is one value pointing north and a
// different one pointing east. The circular EMA then converges to an average
// that is wrong at every heading, the count reaches twenty on the first decent
// leg, and the cluster starts saying `TRUE` about a number it has no business
// trusting. Saying MAG would have been correct and honest.
//
// The gate added here is an EMA of the absolute residual — how far each new
// observation lands from the running offset. It is evaluated only once the
// count bar is already met, and it has a hysteresis band for the same reason
// C1's heading source does: a label that flips between TRUE and MAG on a
// driver-facing cluster reads as a fault.
//
// THE THRESHOLDS ARE A FIRST PASS. 12 degrees to earn TRUE and 20 to lose it
// are chosen from what GPS-course and magnetometer noise plausibly look like,
// not from measurement. docs/ROAD-TEST.md is where they get their real values.

import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/constants/app_constants.dart';
import 'package:irallymeter/features/compass/domain/heading_calibration.dart';

void main() {
  group('C5 · TRUE requires agreement, not just arithmetic', () {
    test('01 · twenty CONTRADICTORY samples do not earn TRUE', () async {
      // THE REGRESSION. Every observation disagrees with the last by 80
      // degrees, so the offset is meaningless — and the old code called it
      // learned on sample twenty regardless.
      final c = HeadingCalibration();
      for (var i = 0; i < 40; i++) {
        c.observe(
          gpsCourseDeg: i.isEven ? 40.0 : 320.0,
          magneticDeg: 0,
          speedMps: 20,
          accuracyM: 5,
        );
      }

      expect(c.samples, greaterThanOrEqualTo(20),
          reason: 'the count bar itself is met — that is the point');
      expect(c.isLearned, isFalse,
          reason: 'forty observations that agree with nothing were accepted as '
              'a measurement, and the cluster went on to label a magnetic '
              'heading TRUE on the strength of them');
    });

    test('02 · consistent samples still earn it', () async {
      // The gate must not break the case it exists to protect.
      final c = _consistent(declination: 5.0, jitter: 0);
      expect(c.isLearned, isTrue);
      expect(c.offsetDeg, closeTo(5.0, 1.0));
    });

    test('03 · REAL sensor noise still earns it', () async {
      // The gate would be worthless if ordinary jitter blocked it forever. A
      // GPS course at 20 m/s and a magnetometer in a car both wander by a few
      // degrees; that is signal-with-noise, not disagreement.
      final c = _consistent(declination: 5.0, jitter: 6);

      expect(c.isLearned, isTrue,
          reason: 'plus or minus 6 degrees of jitter is what a good '
              'installation looks like. If that cannot earn TRUE, the switch '
              'can never do anything and the gate has replaced one lie with '
              'a permanent shrug');
      expect(c.offsetDeg, closeTo(5.0, 3.0));
    });

    test('04 · TRUE is REVOKED when the installation stops agreeing', () async {
      // The phone gets re-seated in the mount, or a speaker magnet ends up next
      // to it. The offset it learned an hour ago is now wrong, and continuing
      // to assert TRUE is the exact failure this class was written to prevent.
      final c = _consistent(declination: 5.0, jitter: 0);
      expect(c.isLearned, isTrue);

      for (var i = 0; i < 40; i++) {
        c.observe(
          gpsCourseDeg: i.isEven ? 100.0 : 260.0,
          magneticDeg: 0,
          speedMps: 20,
          accuracyM: 5,
        );
      }

      expect(c.isLearned, isFalse,
          reason: 'once earned, TRUE was permanent — isLearned could only ever '
              'go from false to true, so a calibration invalidated mid-drive '
              'kept its label');
    });

    test('05 · HYSTERESIS — sitting on the bar must not flap the label',
        () async {
      // Same lesson as C1. A residual parked right at the acquire threshold
      // would toggle TRUE/MAG on alternate fixes with a single threshold, and
      // a cluster whose label blinks reads as a broken cluster.
      final c = _consistent(declination: 5.0, jitter: 0);
      expect(c.isLearned, isTrue);

      final labels = <bool>{};
      for (var i = 0; i < 30; i++) {
        // Residual hovers in the band between acquire and release.
        final wobble = AppConstants.headingCalibrationAgreeDeg + 3.0;
        c.observe(
          gpsCourseDeg: (5.0 + (i.isEven ? wobble : -wobble)) % 360.0,
          magneticDeg: 0,
          speedMps: 20,
          accuracyM: 5,
        );
        labels.add(c.isLearned);
      }

      expect(labels.length, 1,
          reason: 'the TRUE/MAG label changed while the residual sat still '
              'inside the band — that is the boundary flapping the band exists '
              'to prevent');
      expect(labels.single, isTrue,
          reason: 'inside the band the previous state should persist, and it '
              'was learned');
    });

    test('06 · the residual is reported, not just acted on', () async {
      // A gate nobody can read is a gate nobody can debug on a road test.
      expect(_consistent(declination: 5.0, jitter: 0).residualDeg,
          lessThan(AppConstants.headingCalibrationAgreeDeg));
      expect(HeadingCalibration().residualDeg, 0);
    });

    test('07 · reset() clears the agreement state too', () async {
      final c = _consistent(declination: 5.0, jitter: 0);
      expect(c.isLearned, isTrue);
      c.reset();
      expect(c.isLearned, isFalse);
      expect(c.residualDeg, 0);
    });
  });
}

/// A believable good installation: the offset is real, the readings wander.
/// [jitter] is a deterministic sawtooth, not randomness — a test that fails on
/// one run in ten is worse than no test.
HeadingCalibration _consistent({
  required double declination,
  required double jitter,
}) {
  final c = HeadingCalibration();
  const wobble = [0.0, 1.0, -1.0, 0.5, -0.5, 1.0, -1.0];
  for (var i = 0; i < 40; i++) {
    final mag = (i * 9.0) % 360.0;
    final noise = jitter * wobble[i % wobble.length];
    c.observe(
      gpsCourseDeg: (mag + declination + noise + 360.0) % 360.0,
      magneticDeg: mag,
      speedMps: 20,
      accuracyM: 5,
    );
  }
  return c;
}
