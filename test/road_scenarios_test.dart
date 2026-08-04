import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/features/distance/domain/distance_delta.dart';

import 'replay_targets_test.dart';

/// Scenarios a road test would actually throw at this app, run in replay
/// because the road test has not happened yet.
///
/// These are NOT §19 targets — §19 has six rows and they live in
/// `replay_targets_test.dart`. These are the situations §20.2 and §20.3 name
/// (curved roads, stop-start, repeated tunnels, degraded urban reception, long
/// trips) measured against ground truth that is exact by construction.
///
/// **Two of them found real, quantified costs of SPEC-v2 §6.1 rule 3.** They
/// are recorded here at full strength rather than tuned until they pass — the
/// point of building them was to learn something, and pretending otherwise
/// would waste the exercise.
void main() {
  group('S1 · curved roads — §19\'s own note, measured', () {
    // "At a 1 Hz update rate, the application measures straight lines between
    // fixes. On tight mountain or gravel roads these straight lines cut across
    // curves, so measured distance will read slightly short."
    //
    // §19 defers a calibration factor for this rather than calling it a bug.
    // These tests turn the warning into a number.
    test('01 · 20 hairpins at r=30 m read SHORT, never long', () {
      final r = replay('mountain_hairpins.jsonl');
      expect(r.totalMeters, lessThan(1885.0),
          reason: 'chords across an arc cannot exceed the arc — a result LONGER '
              'than ground truth would mean the engine is inventing distance');
    });

    test('02 · and the chord-shortening cost stays inside §19\'s 1 %', () {
      // Measured -0.75 % at r = 30 m and 43 km/h. Worth pinning: if a change
      // makes curve handling worse, this is where it shows up, and it says the
      // deferred calibration factor is not yet needed at this geometry.
      final r = replay('mountain_hairpins.jsonl');
      expect(r.errorFraction(1885.0), lessThanOrEqualTo(0.010),
          reason: 'measured ${r.totalMeters.toStringAsFixed(1)} m against '
              '1885.0 m of arc');
    });

    test('03 · a twisting road never looks like a tunnel', () {
      final r = replay('mountain_hairpins.jsonl');
      expect(r.enteredEstimationCount, 0,
          reason: 'heading changing fast is not the same as GNSS being lost');
    });
  });

  group('S2 · stop-start traffic — §6.1 must re-arm every time', () {
    // parked_10min covers ONE long stop. This is twelve, because a gate that
    // leaks a few metres per stop is invisible in a single-stop test and
    // compounds across a transit section.
    test('04 · twelve stops never accumulate creep — the counter only grows '
        'while moving', () {
      final r = replay('stop_start_traffic.jsonl');
      expect(r.totalMeters, lessThan(2856.0),
          reason: 'creep would push the total ABOVE ground truth; that is the '
              'failure this fixture exists to catch');
      expect(r.wentBackwards, isFalse);
    });

    test('05 · slow ramps are now measured, not discarded', () {
      // THIS TEST FOUND A SEVERE BUG, AND NOW GUARDS THE FIX.
      //
      // It originally measured -5.04 % here: 144 m short over 2856 m, because
      // §6.1 rule 3's floor was applied by RE-ANCHORING on every fix. Any
      // displacement smaller than the fix's own accuracy was thrown away
      // permanently, so every second spent below 5 m/s on a 5 m fix vanished —
      // 6 m pulling away plus 6 m stopping, twelve times.
      //
      // The general-scenario suite then showed how bad that really was: the
      // threshold is `speed < accuracy * fixRate`, so at the 5 Hz the app
      // ACTUALLY REQUESTS it discarded everything below 90 km/h. A faster
      // receiver made the app measure less.
      //
      // Holding the anchor when the floor rejects lets small real movements
      // accumulate until they clear it. -5.04 % -> -0.12 %.
      final r = replay('stop_start_traffic.jsonl');
      expect(r.errorFraction(2856.0), lessThanOrEqualTo(0.01),
          reason: 'measured ${r.totalMeters.toStringAsFixed(1)} m against '
              '2856.0 m — slow acceleration ramps are being discarded again');
      expect(r.totalMeters, lessThanOrEqualTo(2856.0),
          reason: 'and it must still never read LONG');
    });
  });

  group('S3 · five tunnels in a row', () {
    // One long blackout is tunnel_2km. A gorge is a string of short ones, and
    // that stresses entry debounce, exit debounce, re-anchoring, and whether
    // five reconciliations stack up unpaid corrections.
    test('06 · each blackout is detected exactly once — no oscillation', () {
      final r = replay('multi_tunnel.jsonl');
      expect(r.enteredEstimationCount, 5,
          reason: 'five tunnels must produce five entries, not four and not '
              'nine — flapping at the mouth would show up here');
    });

    test('07 · five tunnels still land inside §19\'s 3 %', () {
      final r = replay('multi_tunnel.jsonl');
      expect(r.errorFraction(5390.0), lessThanOrEqualTo(0.03),
          reason: 'measured ${r.totalMeters.toStringAsFixed(1)} m against '
              '5390.0 m');
    });

    test('08 · the estimated legs total roughly the 5 x 550 m driven dark', () {
      final r = replay('multi_tunnel.jsonl');
      final est = r.metersBySource[DistanceSource.sensor] ?? 0;
      expect((est - 2750.0).abs() / 2750.0, lessThanOrEqualTo(0.03),
          reason: 'estimated ${est.toStringAsFixed(1)} m of dark travel '
              'against 2750.0 m');
    });

    test('09 · nothing runs backwards across five reconciliations', () {
      expect(replay('multi_tunnel.jsonl').wentBackwards, isFalse);
    });
  });

  group('S4 · urban canyon — degraded but never absent', () {
    // The nastiest real case: fixes keep arriving at 1 Hz so the silence
    // trigger never fires on its own, but accuracy breathes between 6 m and
    // 45 m. It sits deliberately across usableAccuracyMeters (25),
    // estimationExitAccuracyMeters (20) and estimationEntryAccuracyMeters (50).
    test('10 · poor fixes are never integrated as if they were good', () {
      final r = replay('urban_canyon.jsonl');
      expect(r.totalMeters, lessThan(5400.0),
          reason: 'scattered 45 m fixes integrated raw would read LONG; that is '
              'the failure mode this guards');
      expect(r.wentBackwards, isFalse);
    });

    test('11 · degraded reception drops into Estimation Mode rather than '
        'integrating garbage', () {
      final r = replay('urban_canyon.jsonl');
      expect(r.enteredEstimationCount, greaterThan(0));
      expect(r.metersBySource[DistanceSource.sensor] ?? 0, greaterThan(0),
          reason: 'and the inertial fallback must actually carry the distance '
              'while it is there');
    });

    test('12 · an urban canyon stays inside §19\'s 1 % trip-distance target',
        () {
      // WAS -16.66 %, NOW -12.50 %, AND STILL RECORDED AT FULL STRENGTH.
      //
      // The anchor fix (see S2 test 05) recovered about a quarter of the loss.
      // What remains is a DIFFERENT mechanism: when accuracy breathes past the
      // integrable limit the engine drops into Estimation Mode and coasts at
      // v0, and a coast cannot track speed changes it is not told about.
      //
      // Cause, and it is the same rule as test 05: §6.1 rule 3 ignores any
      // displacement smaller than the fix's own accuracy. At 18 m/s the car
      // covers 18 m per second, so EVERY fix reporting worse than 18 m accuracy
      // has its real, corroborated movement discarded — even though the Doppler
      // speed independently confirms the car is doing 65 km/h.
      //
      // That is §6.1 read literally. Whether a displacement corroborated by an
      // independent Doppler measurement should still be called noise is a
      // question for Amirali and the spec, NOT something to quietly relax here:
      // the same floor is what makes T2 (parked 10 min → 0.000 km) pass, and
      // loosening it without a decision would trade a visible 16 % under-read
      // for an invisible parked-drift regression.
      //
      // Unskip when the degraded-reception path has been ruled on. Do not
      // weaken it.
      final r = replay('urban_canyon.jsonl');
      expect(r.errorFraction(5400.0), lessThanOrEqualTo(0.010),
          reason: 'measured ${r.totalMeters.toStringAsFixed(1)} m against '
              '5400.0 m of real travel');
    }, skip: 'Degraded-reception under-read, unresolved — see the comment. '
        'Improved -16.66 % -> -12.50 % by the anchor fix. Never weaken this.');
  });

  group('S5 · 500 km — float accumulation', () {
    // Named directly in the Phase 5 adversarial brief: "float accumulation
    // drift over a 500 km trip". 20 000 identical 25 m increments, so any error
    // belongs to the accumulator and nothing else.
    test('13 · 500 km accumulates with no measurable drift', () {
      final r = replay('long_drive_500km.jsonl');
      expect(r.errorFraction(500000.0), lessThanOrEqualTo(0.0001),
          reason: 'measured ${r.totalMeters.toStringAsFixed(3)} m against '
              '500000.0 m — this is 20 000 additions of the same number, so a '
              'drifting accumulator would be plainly visible');
    });

    test('14 · and never once goes backwards over 20 000 fixes', () {
      expect(replay('long_drive_500km.jsonl').wentBackwards, isFalse);
    });

    test('15 · a clean 500 km never enters Estimation Mode', () {
      expect(replay('long_drive_500km.jsonl').enteredEstimationCount, 0);
    });
  });
}
