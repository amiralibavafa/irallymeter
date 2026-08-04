import '../../../core/constants/app_constants.dart';
import '../../distance/domain/distance_delta.dart';
import '../../distance/domain/distance_engine.dart';
import '../../distance/domain/distance_engine_state.dart';
import 'trace_event.dart';

/// What a replayed trace did to the Distance Engine.
class ReplayResult {
  ReplayResult({
    required this.totalMeters,
    required this.metersBySource,
    required this.wentBackwards,
    required this.enteredEstimationCount,
    required this.estimatedMeters,
    required this.maxReconcileGapMs,
    required this.durationMs,
  });

  /// Everything the engine emitted, from every source.
  final double totalMeters;

  /// Same total, split by where the metres came from.
  final Map<DistanceSource, double> metersBySource;

  /// True if the running total ever decreased. SPEC-v2 §16.1 says the counters
  /// must never move backwards, so this is a hard assertion, not a statistic.
  final bool wentBackwards;

  /// How many times the engine entered Estimation Mode.
  final int enteredEstimationCount;

  /// Metres attributed to the sensor estimate while in Estimation Mode.
  final double estimatedMeters;

  /// Longest single reconciliation, start of payout to settled (ms). §19 caps
  /// this at 15 000.
  final int maxReconcileGapMs;

  final int durationMs;

  double get totalKm => totalMeters / 1000.0;

  /// Error against a known ground truth, as a fraction (0.01 == 1 %).
  double errorFraction(double truthMeters) =>
      truthMeters <= 0 ? 0 : (totalMeters - truthMeters).abs() / truthMeters;
}

/// Replays a recorded trace into a [DistanceEngine], headlessly (SPEC-v2 §20.1).
///
/// This is the other half of the record-and-replay loop, and the reason
/// SPEC-v2 §17 insists the engine be pure Dart: no widgets, no plugins, no
/// platform channels, so the whole thing runs inside `flutter test`.
///
/// ## Why it synthesises its own ticks
///
/// [DistanceEngine.tick] is not decoration. Estimation Mode is entered when
/// fixes STOP arriving, which by definition no incoming sample can announce —
/// the engine only learns about a tunnel because a heartbeat notices the
/// silence. A player that fed only the recorded events would therefore never
/// reproduce a tunnel at all, and `tunnel_2km.jsonl` would silently pass by
/// measuring nothing. So the player drives a virtual clock forward in
/// [AppConstants.engineTick] steps and delivers events as that clock reaches
/// them, exactly as the running app does.
///
/// The clock is virtual, so a 10-minute fixture replays in milliseconds.
class TracePlayer {
  TracePlayer({DateTime? epoch})
      : _epoch = epoch ?? DateTime.utc(2026, 1, 1);

  /// Arbitrary but fixed, so replays are reproducible. Traces store relative
  /// offsets; this is only what they are relative TO.
  final DateTime _epoch;

  ReplayResult play(List<TraceEvent> events) {
    if (events.isEmpty) {
      return ReplayResult(
        totalMeters: 0,
        metersBySource: const {},
        wentBackwards: false,
        enteredEstimationCount: 0,
        estimatedMeters: 0,
        maxReconcileGapMs: 0,
        durationMs: 0,
      );
    }

    var total = 0.0;
    var previousTotal = 0.0;
    var wentBackwards = false;
    var estimated = 0.0;
    var entries = 0;
    final bySource = <DistanceSource, double>{};

    var wasEstimating = false;
    var reconcileStartMs = -1;
    var maxReconcileGapMs = 0;
    var nowMs = 0;

    final engine = DistanceEngine(
      onDelta: (DistanceDelta d) {
        total += d.meters;
        bySource[d.source] = (bySource[d.source] ?? 0) + d.meters;
        if (d.source == DistanceSource.sensor) estimated += d.meters;
        // Monotonicity is checked on the accumulated total, not on the sign of
        // an individual delta: the engine could in principle emit a negative
        // increment that a larger positive one hides, and it is what the
        // co-driver READS that must never decrease.
        if (total < previousTotal - 1e-9) wentBackwards = true;
        previousTotal = total;
      },
      onState: (DistanceEngineState s) {
        if (s.tunnelMode && !wasEstimating) entries++;
        wasEstimating = s.tunnelMode;

        if (s.reconciling && reconcileStartMs < 0) {
          reconcileStartMs = nowMs;
        } else if (!s.reconciling && reconcileStartMs >= 0) {
          final span = nowMs - reconcileStartMs;
          if (span > maxReconcileGapMs) maxReconcileGapMs = span;
          reconcileStartMs = -1;
        }
      },
    );

    final lastMs = events.last.offsetMs;
    final stepMs = AppConstants.engineTick.inMilliseconds;
    var next = 0;

    // Walk the virtual clock. Events land at or before the tick that reaches
    // them; the tick then runs, so dropout detection and reconciliation payout
    // see the same ordering they would at runtime.
    for (nowMs = 0; nowMs <= lastMs + stepMs; nowMs += stepMs) {
      while (next < events.length && events[next].offsetMs <= nowMs) {
        final e = events[next++];
        final at = _epoch.add(Duration(milliseconds: e.offsetMs));
        switch (e) {
          case GpsTraceEvent():
            engine.onGpsSample(e.toSample(_epoch), at);
          case MotionTraceEvent():
            engine.onMotionSample(e.toSample(_epoch), at);
        }
      }
      engine.tick(_epoch.add(Duration(milliseconds: nowMs)));
    }

    // A payout still in flight when the trace ends is measured to the end.
    if (reconcileStartMs >= 0) {
      final span = nowMs - reconcileStartMs;
      if (span > maxReconcileGapMs) maxReconcileGapMs = span;
    }

    return ReplayResult(
      totalMeters: total,
      metersBySource: bySource,
      wentBackwards: wentBackwards,
      enteredEstimationCount: entries,
      estimatedMeters: estimated,
      maxReconcileGapMs: maxReconcileGapMs,
      durationMs: lastMs,
    );
  }

  /// Convenience: parse raw JSONL and play it.
  ReplayResult playLines(Iterable<String> lines) =>
      play(TraceEvent.parseAll(lines));
}
