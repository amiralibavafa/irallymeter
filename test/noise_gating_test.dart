import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/core/constants/app_constants.dart';
import 'package:irallymeter/features/distance/domain/gps_distance_source.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';

/// SPEC-v2 §6.1 — "A stationary vehicle must never accumulate distance."
///
/// The target these serve is §19's "Vehicle parked for 10 minutes → 0.000 km",
/// verified end-to-end against a real trace in `replay_targets_test.dart` (T2).
/// These are the unit-level rules underneath it.
const double degPerM = 8.993216059187306e-6;

GpsSample fix({
  required int atMs,
  required double northM,
  double speed = 0,
  double speedAcc = double.nan,
  double accuracy = 5.0,
}) =>
    GpsSample(
      timestamp: DateTime.utc(2026).add(Duration(milliseconds: atMs)),
      latitude: 35.0 + northM * degPerM,
      longitude: 51.389,
      speedMps: speed,
      speedAccuracyMps: speedAcc,
      headingDeg: 0,
      accuracyM: accuracy,
      altitudeM: 1200,
      hasFix: true,
    );

void main() {
  group('§6.1 rule 1 · accuracy rejection', () {
    test('01 · a fix worse than the usable accuracy is rejected outright', () {
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, northM: 0));
      expect(src.add(fix(atMs: 1000, northM: 25, accuracy: 40)), isNull,
          reason: '§6.1 requires rejecting anything worse than 30 m; the app '
              'is stricter still at ${AppConstants.usableAccuracyMeters} m');
    });
  });

  group('§6.1 rule 2 · the 1.5 m/s moving gate', () {
    test('02 · a credible Doppler below 1.5 m/s zeroes the displacement', () {
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, northM: 0, speed: 0.8, speedAcc: 0.5));
      // 9 m of drift in one second, but the receiver credibly says 0.8 m/s.
      final d = src.add(
          fix(atMs: 1000, northM: 9, speed: 0.8, speedAcc: 0.5))!;
      expect(d.meters, 0.0);
      expect(d.dt.inMilliseconds, 1000,
          reason: 'an ACCEPTED pair that covered no ground — elapsed time must '
              'still accrue so a running average decays toward zero');
    });

    test('03 · at exactly 1.5 m/s the vehicle counts as moving (boundary)', () {
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, northM: 0, speed: 1.5, speedAcc: 0.5));
      final d = src.add(
          fix(atMs: 1000, northM: 9, speed: 1.5, speedAcc: 0.5))!;
      expect(d.meters, greaterThan(0));
      expect(AppConstants.movingThresholdMps, 1.5);
    });

    test('04 · a Doppler of EXACTLY zero does not veto a real displacement',
        () {
      // The regression that broke 14 existing tests when this rule was first
      // written. Platforms with no speed support report 0.0 — not null, not
      // NaN. Trusting that zero gates out every metre and the app measures
      // nothing at all on those devices.
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, northM: 0, speed: 0));
      final d = src.add(fix(atMs: 1000, northM: 25, speed: 0))!;
      expect(d.meters, closeTo(25, 0.1),
          reason: 'when the receiver says zero, the positions get to speak');
    });
  });

  group('§6.1 rule 3 · the accuracy-relative floor', () {
    test('05 · a displacement smaller than the fix accuracy is noise', () {
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, northM: 0, speed: 10, speedAcc: 0.5, accuracy: 20));
      // 12 m of movement reported by a fix that is itself +/-20 m.
      final d = src.add(
          fix(atMs: 1000, northM: 12, speed: 10, speedAcc: 0.5, accuracy: 20))!;
      expect(d.meters, 0.0,
          reason: 'the movement cannot be distinguished from the fix error');
    });

    test('06 · the same displacement counts when the fix is precise', () {
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, northM: 0, speed: 10, speedAcc: 0.5, accuracy: 4));
      final d = src.add(
          fix(atMs: 1000, northM: 12, speed: 10, speedAcc: 0.5, accuracy: 4))!;
      expect(d.meters, closeTo(12, 0.1),
          reason: 'the floor is the FIX\'S OWN accuracy, not a constant — this '
              'is what a fixed 1.0 m floor got wrong');
    });

    test('07 · a good fix still floors below the absolute minimum', () {
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, northM: 0, speed: 10, speedAcc: 0.5, accuracy: 0.2));
      final d = src.add(fix(
          atMs: 1000, northM: 0.5, speed: 10, speedAcc: 0.5, accuracy: 0.2))!;
      expect(d.meters, 0.0,
          reason: 'minMovementMeters remains the absolute floor even when a fix '
              'claims sub-metre accuracy');
    });
  });

  group('§6.1 · a parked vehicle over time', () {
    test('08 · 5 minutes of drift accumulates exactly nothing', () {
      final src = GpsDistanceSource();
      var total = 0.0;
      // Deterministic sawtooth wander of +/-6 m around a point, on 8 m fixes,
      // with the small non-zero speed a real receiver reports while parked.
      for (var i = 0; i <= 300; i++) {
        final wander = (i % 4 < 2 ? 6.0 : -6.0) * ((i % 8 < 4) ? 1 : 0.5);
        final d = src.add(fix(
          atMs: i * 1000,
          northM: wander,
          speed: 0.4,
          speedAcc: 1.0,
          accuracy: 8,
        ));
        total += d?.meters ?? 0;
      }
      expect(total, 0.0,
          reason: 'accumulated ${total.toStringAsFixed(3)} m while parked');
    });
  });

  group('§6.1 rule 4 · the 3x jump rejection', () {
    test('09 · a jump beyond 3x the expected displacement is rejected', () {
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, northM: 0, speed: 20, speedAcc: 0.5));
      src.add(fix(atMs: 1000, northM: 20, speed: 20, speedAcc: 0.5));
      // Doing 20 m/s, so ~20 m is expected over the next second. 100 m is not.
      expect(
        src.add(fix(atMs: 2000, northM: 120, speed: 20, speedAcc: 0.5)),
        isNull,
        reason: 'a fix inconsistent with the last known speed is a bad fix, '
            'not real movement',
      );
      expect(AppConstants.maxJumpFactor, 3.0);
    });

    test('10 · a jump just inside 3x is accepted', () {
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, northM: 0, speed: 20, speedAcc: 0.5));
      src.add(fix(atMs: 1000, northM: 20, speed: 20, speedAcc: 0.5));
      final d = src.add(fix(atMs: 2000, northM: 79, speed: 20, speedAcc: 0.5));
      expect(d, isNotNull, reason: '59 m against an expected 20 m is under 3x');
    });

    test('11 · pulling away from a standstill is NOT rejected', () {
      // The gate that makes rule 4 safe. Three times an expected displacement
      // of ~0 is still 0, so an ungated rule rejects every launch and the trip
      // never starts.
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, northM: 0, speed: 0.2, speedAcc: 0.5));
      src.add(fix(atMs: 1000, northM: 0.3, speed: 0.2, speedAcc: 0.5));
      final d = src.add(fix(atMs: 2000, northM: 25, speed: 25, speedAcc: 0.5));
      expect(d, isNotNull);
      expect(d!.meters, greaterThan(0));
    });

    test('12 · a rejected fix is not the baseline for the one after it', () {
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, northM: 0, speed: 20, speedAcc: 0.5));
      src.add(fix(atMs: 1000, northM: 20, speed: 20, speedAcc: 0.5));
      src.add(fix(atMs: 2000, northM: 120, speed: 20, speedAcc: 0.5)); // rejected
      // The next honest fix must be able to resume, not be judged against a
      // speed derived from the rejection.
      final d = src.add(fix(atMs: 3000, northM: 140, speed: 20, speedAcc: 0.5));
      expect(d, isNotNull);
    });
  });
}
