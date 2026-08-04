import '../../../core/constants/app_constants.dart';
import 'distance_engine_state.dart';

/// Is this number measured, or guessed? (SPEC-v2 §5.1)
enum MeasurementState {
  /// GNSS is valid and accurate. Normal digit colour.
  measured,

  /// Estimation Mode — the figure comes from dead reckoning, not the receiver.
  estimated,

  /// GNSS is back and a recovery correction is still being paid out.
  reconciling,
}

/// How much the estimate has decayed (SPEC-v2 §12.3).
enum EstimationConfidence {
  /// 0–60 s without GNSS.
  normal,

  /// 60–180 s — "indicator becomes more prominent".
  reduced,

  /// Over 180 s — "the display warns that the distance may be significantly
  /// wrong".
  low,
}

/// What the dashboard must tell the driver about the numbers it is showing.
///
/// SPEC-v2 §16.2, and the reason this type exists at all:
///
///   "Hide the correction. Never hide the estimation."
///
/// §16.1 makes the post-recovery correction invisible — blended in so the trip
/// counter never jumps. That is deliberate. But it applies ONLY to the
/// correction. Whether the app is currently guessing is the opposite kind of
/// fact: it must be impossible to miss. A co-driver calling "left in 300 metres"
/// off a number has to know whether that number was measured or dead-reckoned,
/// because the whole product rests on "the user should trust the numbers
/// displayed by the application" (§1).
///
/// Pure Dart, derived from [DistanceEngineState] plus a clock the caller
/// supplies, so the tier boundaries are testable without waiting three minutes.
class MeasurementStatus {
  const MeasurementStatus({
    required this.state,
    required this.confidence,
    required this.estimatingFor,
  });

  final MeasurementState state;
  final EstimationConfidence confidence;

  /// How long the current Estimation Mode has been running (zero when measured).
  final Duration estimatingFor;

  /// True whenever the displayed figures are not straight from the receiver.
  bool get isEstimated => state == MeasurementState.estimated;

  /// True when §12.3 says the figures should be marked as unreliable, not
  /// merely estimated.
  bool get isLowConfidence => confidence == EstimationConfidence.low;

  /// The short badge shown beside the affected values. Null when measured —
  /// a measured reading carries no decoration at all, so the presence of ANY
  /// badge means "not measured".
  String? get badge => switch (state) {
        MeasurementState.measured => null,
        MeasurementState.reconciling => 'SYNC',
        MeasurementState.estimated =>
          confidence == EstimationConfidence.low ? 'EST?' : 'EST',
      };

  static const MeasurementStatus measured = MeasurementStatus(
    state: MeasurementState.measured,
    confidence: EstimationConfidence.normal,
    estimatingFor: Duration.zero,
  );

  /// Derive the display state from the engine.
  ///
  /// Estimation outranks reconciliation: if GNSS dropped again while a
  /// correction was still paying out, the honest thing to show is that we are
  /// guessing now, not that we are tidying up from last time.
  factory MeasurementStatus.from(DistanceEngineState s, DateTime now) {
    if (s.tunnelMode) {
      final since = s.tunnelSince;
      final elapsed = since == null ? Duration.zero : now.difference(since);
      return MeasurementStatus(
        state: MeasurementState.estimated,
        confidence: _confidenceFor(elapsed),
        estimatingFor: elapsed.isNegative ? Duration.zero : elapsed,
      );
    }
    if (s.reconciling) {
      return const MeasurementStatus(
        state: MeasurementState.reconciling,
        confidence: EstimationConfidence.normal,
        estimatingFor: Duration.zero,
      );
    }
    return measured;
  }

  static EstimationConfidence _confidenceFor(Duration d) {
    if (d >= AppConstants.lowConfidenceAfter) return EstimationConfidence.low;
    if (d >= AppConstants.reducedConfidenceAfter) {
      return EstimationConfidence.reduced;
    }
    return EstimationConfidence.normal;
  }

  /// Whether the accumulated-distance readouts (trip, odometer, average speed)
  /// are currently carrying estimated metres.
  ///
  /// They all consume the same `DistanceDelta` stream, so if any of them is
  /// showing an estimate, ALL of them are. Showing only some in amber would be
  /// worse than showing none: the driver would reasonably read the white ones
  /// as measured.
  bool get affectsAccumulatedDistance =>
      state != MeasurementState.measured;
}
