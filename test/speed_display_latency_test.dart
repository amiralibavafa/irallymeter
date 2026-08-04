import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/features/gps/domain/gps_state.dart';

/// SPEC-v2 §19, row 3 — the accuracy target nothing was testing.
///
///   | Displayed speed | Above 20 km/h, good reception | ±2 km/h, latency ≤ 1.0 s |
///
/// and SPEC-v2 §7.2:
///
///   "Smoothing must not add more than approximately 1 second of latency. The
///    goal is a stable display, not a slow one."
///
/// The other five §19 rows are covered in replay_targets_test.dart as T1–T6.
/// This row was missed: T6 is a bonus full-trace check, not a §19 row, so
/// "all six targets pass" was counting the wrong six. Row 6 (sustained ≥1 Hz
/// update rate) is a platform property and is not unit-testable here.
///
/// ## Why the fix rate is the whole story
///
/// The filter is an exponential moving average. Applied PER SAMPLE, its lag in
/// SECONDS is whatever the fix rate happens to be — the same filter is fast on
/// a 5 Hz chip and slow on a 1 Hz one. §19 states the budget in seconds, and
/// §19 row 6 baselines the rate at 1 Hz, which is what most Android GPS chips
/// actually deliver (see the note on `AppConstants.gpsInterval`). So 1 Hz is
/// the case that has to pass, not the optimistic one.
const double kmh = 1000.0 / 3600.0;

/// Seconds until the filter's output settles within [toleranceKmh] of a step
/// to [targetKmh], sampled every [period]. Returns null if it never does.
double? settleSeconds({
  required double targetKmh,
  required Duration period,
  double toleranceKmh = 2.0,
  Duration limit = const Duration(seconds: 30),
}) {
  final f = SpeedFilter();
  var t = DateTime.utc(2026);

  // Seed at a steady 25 km/h — "above 20 km/h", per the row's condition — so
  // the step is measured from a settled state, not from the seeding sample.
  for (var i = 0; i < 10; i++) {
    f.add(25 * kmh, 5, t);
    t = t.add(period);
  }

  final start = t;
  while (t.difference(start) <= limit) {
    final shown = f.add(targetKmh * kmh, 5, t);
    if ((shown / kmh - targetKmh).abs() <= toleranceKmh) {
      return t.difference(start).inMicroseconds / 1e6;
    }
    t = t.add(period);
  }
  return null;
}

void main() {
  group('§19 row 3 · displayed speed latency ≤ 1.0 s', () {
    test('T7 · settles within 2 km/h in ≤ 1 s at the spec baseline of 1 Hz',
        () {
      final s = settleSeconds(targetKmh: 100, period: const Duration(seconds: 1));
      expect(s, isNotNull, reason: 'the display must converge at all');
      expect(s, lessThanOrEqualTo(1.0),
          reason: '§19 budgets the latency in SECONDS and §19 row 6 baselines '
              'the fix rate at 1 Hz. A per-sample EMA makes the lag depend on '
              'the chip, so a filter tuned on a 5 Hz device silently misses '
              'this target on the 1 Hz devices the spec assumes.');
    });

    test('T7b · and still meets it at 5 Hz, the rate the app requests', () {
      final s =
          settleSeconds(targetKmh: 100, period: const Duration(milliseconds: 200));
      expect(s, isNotNull);
      expect(s, lessThanOrEqualTo(1.0));
    });

    test('T7c · a deceleration settles just as fast as an acceleration', () {
      // Braking into a hairpin is the case a co-driver actually reads.
      final f = SpeedFilter();
      var t = DateTime.utc(2026);
      for (var i = 0; i < 10; i++) {
        f.add(100 * kmh, 5, t);
        t = t.add(const Duration(seconds: 1));
      }
      final start = t;
      double? settled;
      while (t.difference(start) <= const Duration(seconds: 30)) {
        final shown = f.add(30 * kmh, 5, t);
        if ((shown / kmh - 30).abs() <= 2.0) {
          settled = t.difference(start).inMicroseconds / 1e6;
          break;
        }
        t = t.add(const Duration(seconds: 1));
      }
      expect(settled, isNotNull);
      expect(settled, lessThanOrEqualTo(1.0));
    });

    test('T7d · the display is still SMOOTHED, not passed through raw', () {
      // §7.2 wants "a stable display, not a slow one" — fixing the latency
      // must not turn the filter off. The spec's own example: raw 70, 95, 40,
      // 85 must not appear on screen as 70, 95, 40, 85.
      final f = SpeedFilter();
      var t = DateTime.utc(2026);
      final shown = <double>[];
      for (final raw in [70.0, 95.0, 40.0, 85.0]) {
        shown.add(f.add(raw * kmh, 5, t) / kmh);
        t = t.add(const Duration(seconds: 1));
      }
      // First sample seeds. After that every reading must be pulled toward the
      // running value rather than jumping to the raw one.
      expect(shown[1], lessThan(95.0), reason: 'a 95 spike must be damped');
      expect(shown[2], greaterThan(40.0), reason: 'a 40 dropout must be damped');
      expect(shown[3], lessThan(85.0));
    });

    test('T7e · irregular fix intervals do not change the settling TIME', () {
      // The whole point: latency is a property of the clock, not of how many
      // samples happen to arrive.
      final oneHz =
          settleSeconds(targetKmh: 100, period: const Duration(seconds: 1))!;
      final fiveHz = settleSeconds(
          targetKmh: 100, period: const Duration(milliseconds: 200))!;
      expect((oneHz - fiveHz).abs(), lessThan(1.0),
          reason: 'a 5x change in fix rate must not change the latency by '
              'more than a sample interval');
    });
  });
}
