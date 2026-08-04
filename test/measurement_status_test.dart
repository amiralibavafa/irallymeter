import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/features/distance/domain/distance_engine_state.dart';
import 'package:irallymeter/features/distance/domain/measurement_status.dart';

/// SPEC-v2 §5.1, §12.3 and §16.2 — what the dashboard tells the driver about
/// the numbers it is showing.
///
///   "Hide the correction. Never hide the estimation."
final t0 = DateTime.utc(2026);

DistanceEngineState state({
  bool tunnel = false,
  bool reconciling = false,
  DateTime? since,
}) =>
    DistanceEngineState.initial.copyWith(
      tunnelMode: tunnel,
      reconciling: reconciling,
      tunnelSince: since,
    );

MeasurementStatus at(DistanceEngineState s, int seconds) =>
    MeasurementStatus.from(s, t0.add(Duration(seconds: seconds)));

void main() {
  group('§5.1 · measured vs estimated', () {
    test('01 · a healthy engine reports MEASURED and shows no badge', () {
      final s = at(state(), 0);
      expect(s.state, MeasurementState.measured);
      expect(s.badge, isNull,
          reason: 'a measured reading carries no decoration at all, so the '
              'presence of ANY badge means "not measured"');
      expect(s.isEstimated, isFalse);
    });

    test('02 · Estimation Mode reports ESTIMATED', () {
      final s = at(state(tunnel: true, since: t0), 10);
      expect(s.state, MeasurementState.estimated);
      expect(s.badge, 'EST');
      expect(s.isEstimated, isTrue);
    });

    test('03 · a payout in progress reports RECONCILING', () {
      final s = at(state(reconciling: true), 0);
      expect(s.state, MeasurementState.reconciling);
      expect(s.badge, 'SYNC');
    });

    test('04 · estimating outranks reconciling', () {
      // If GNSS dropped again mid-payout, the honest thing to show is that we
      // are guessing NOW, not that we are tidying up from last time.
      final s = at(state(tunnel: true, reconciling: true, since: t0), 5);
      expect(s.state, MeasurementState.estimated);
    });
  });

  group('§12.3 · confidence decay', () {
    test('05 · under 60 s is normal confidence', () {
      expect(at(state(tunnel: true, since: t0), 59).confidence,
          EstimationConfidence.normal);
    });

    test('06 · 60 s exactly crosses into reduced (boundary)', () {
      expect(at(state(tunnel: true, since: t0), 60).confidence,
          EstimationConfidence.reduced);
    });

    test('07 · 180 s exactly crosses into low (boundary)', () {
      final s = at(state(tunnel: true, since: t0), 180);
      expect(s.confidence, EstimationConfidence.low);
      expect(s.isLowConfidence, isTrue);
    });

    test('08 · low confidence changes the badge, not just its colour', () {
      // Colour alone is not an indicator: it fails in sunlight, on a night
      // cluster, and for a colour-blind co-driver. The TEXT has to change.
      expect(at(state(tunnel: true, since: t0), 200).badge, 'EST?');
      expect(at(state(tunnel: true, since: t0), 30).badge, 'EST');
    });

    test('09 · the tiers escalate and never regress while estimating', () {
      final s = state(tunnel: true, since: t0);
      var previous = 0;
      for (final secs in [0, 30, 59, 60, 120, 179, 180, 400]) {
        final rank = switch (at(s, secs).confidence) {
          EstimationConfidence.normal => 0,
          EstimationConfidence.reduced => 1,
          EstimationConfidence.low => 2,
        };
        expect(rank, greaterThanOrEqualTo(previous),
            reason: 'confidence must decay monotonically, never recover while '
                'still estimating');
        previous = rank;
      }
    });

    test('10 · a missing tunnelSince degrades safely, not into a crash', () {
      final s = at(state(tunnel: true), 100);
      expect(s.state, MeasurementState.estimated);
      expect(s.estimatingFor, Duration.zero);
    });

    test('11 · a clock that runs backwards never yields a negative duration',
        () {
      final s = MeasurementStatus.from(
        state(tunnel: true, since: t0.add(const Duration(seconds: 30))),
        t0,
      );
      expect(s.estimatingFor, Duration.zero);
    });
  });
}
