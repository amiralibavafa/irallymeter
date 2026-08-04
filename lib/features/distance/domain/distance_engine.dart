import '../../../core/constants/app_constants.dart';
import '../../../core/utils/geo_math.dart';
import '../../gps/domain/gps_sample.dart';
import 'distance_delta.dart';
import 'distance_engine_state.dart';
import 'distance_reconciler.dart';
import 'estimated_section.dart';
import 'gps_distance_source.dart';
import 'longitudinal_axis_estimator.dart';
import 'motion_sample.dart';
import 'sensor_distance_source.dart';

/// Arbitrates the distance sources and owns the tunnel state machine.
///
/// The trip computer and average-speed integrator consume [onDelta] and never
/// touch GPS directly, so "where did these metres come from" is decided here,
/// once, in one place:
///
///   1. [DistanceSource.gps]    — ground truth. Used whenever GPS is healthy.
///   2. [DistanceSource.sensor] — estimate. Used in Tunnel Mode.
///
/// SPEC-v2 §14 removed manual correction from the priority list entirely: "All
/// estimation is automatic (see Section 15)." There is no driver override.
///
/// ## Tunnel detection
///
/// GPS is "unhealthy" when fixes stop arriving OR arrive with accuracy worse
/// than [AppConstants.usableAccuracyMeters]. Both collapse to a single test —
/// "how long since the last fix we would have integrated" — which is why the
/// engine needs a [tick] heartbeat: a detector that only ran on incoming
/// samples could never notice that samples had stopped.
///
/// Entry requires a prior good fix. That is not just hysteresis: without one
/// there is no entry speed to anchor the estimate to, so a cold start with no
/// signal correctly waits for a fix rather than estimating from nothing.
///
/// ## Recovery
///
/// On exit the GPS source is re-anchored (never integrating the blackout chord
/// on top of the estimate), and the estimate is reconciled against GPS truth —
/// paid out smoothly, never snapped. See [_exitTunnel] for why only undershoot
/// is corrected.
///
/// Pure Dart: no plugins, and every method takes `now` explicitly rather than
/// reading the clock, so the whole state machine is deterministically testable.
class DistanceEngine {
  DistanceEngine({required this.onDelta, required this.onState, this.onSection});

  /// Emits every distance increment, whatever its source.
  final void Function(DistanceDelta) onDelta;

  /// Emits whenever the engine's observable state changes.
  final void Function(DistanceEngineState) onState;

  /// Emits a completed §15.3 record each time Estimation Mode ends. Optional:
  /// the log is always kept in [sections] regardless, so a caller that only
  /// wants to read it afterwards doesn't have to subscribe.
  final void Function(EstimatedSection)? onSection;

  final GpsDistanceSource _gps = GpsDistanceSource();
  final LongitudinalAxisEstimator _axis = LongitudinalAxisEstimator();
  late final SensorDistanceSource _sensor = SensorDistanceSource(_axis);
  final DistanceReconciler _reconciler = DistanceReconciler();
  final EstimatedSectionLog _sections = EstimatedSectionLog();

  /// SPEC-v2 §15.3 — every estimated section of this leg, oldest first.
  EstimatedSectionLog get sections => _sections;

  DistanceEngineState _state = DistanceEngineState.initial;
  DistanceEngineState get state => _state;

  // --- GPS health tracking (wall clock — see class doc) ---
  DateTime? _lastHealthyAt;
  GpsSample? _lastHealthySample;
  double _gpsSpeedMps = 0;

  // --- Tunnel bookkeeping ---
  GpsSample? _tunnelEntryFix;

  /// When the inertial stream last delivered. A suspended app stops producing
  /// motion samples; a car in a tunnel does not. That difference is what tells
  /// a real blackout from a backgrounded process — see [_motionContinuous].
  DateTime? _lastMotionAt;

  /// Whether the inertial stream has run without a suspension-sized gap for the
  /// whole of the current blackout. This is the evidence that lets a genuinely
  /// long tunnel be reconciled instead of being written off as a suspension.
  bool _motionContinuous = false;

  /// The entry-speed anchor the current estimate was seeded with. §15.3 calls
  /// this "the speed that was held"; it is captured at entry rather than read
  /// back at exit because [_gpsSpeedMps] has moved on by then.
  double _tunnelEntrySpeedMps = 0;

  /// How many consecutive fixes have met BOTH §15.2 exit tests. Reset to zero
  /// by any fix that fails either, so recovery must be confirmed afresh.
  int _recoveryStreak = 0;

  /// The last fix counted toward [_recoveryStreak], kept so the next one can be
  /// checked for mutual consistency against it.
  GpsSample? _recoveryLast;

  // ===========================================================================
  // Inputs
  // ===========================================================================

  /// Fold in a GPS fix. [now] is wall-clock; the fix carries its own timestamp.
  void onGpsSample(GpsSample s, DateTime now) {
    final healthy = GpsDistanceSource.isHealthy(s);

    if (!healthy) {
      // An unhealthy fix is indistinguishable from no fix for our purposes:
      // don't refresh the health clock, and drop the recovery streak.
      _recoveryStreak = 0;
      _recoveryLast = null;
      _maybeEnterTunnel(now,
          degradedFixAccuracyM: s.hasFix ? s.accuracyM : null);
      return;
    }

    // Teach the forward axis from real GPS acceleration while we can.
    _learnAxisFrom(s);

    _lastHealthyAt = now;
    _lastHealthySample = s;

    // Track the entry-speed anchor from the fix itself, not just from emitted
    // increments: the very first fix produces no increment (it only anchors),
    // and a tunnel entered right after it would otherwise seed the estimate at
    // a standstill and coast at zero through the whole blackout.
    if (s.speedMps.isFinite && s.speedMps >= 0) _gpsSpeedMps = s.speedMps;

    if (_state.tunnelMode) {
      // Hold the estimate until recovery is confirmed — a tunnel exit throws
      // out a burst of plausible-looking but wrong fixes.
      _maybeExitTunnel(s, now);
      return;
    }

    final delta = _gps.add(s);
    if (delta == null) return;

    _gpsSpeedMps = delta.speedMps;
    _emit(delta);
    _publish(_state.copyWith(source: DistanceSource.gps, speedMps: delta.speedMps));
  }

  /// Fold in a motion sample. Used to learn the forward axis in clear air, and
  /// to estimate distance while in Tunnel Mode.
  void onMotionSample(MotionSample m, DateTime now) {
    _noteMotion(now);
    _pendingMotion = m;
    if (!_state.tunnelMode) return;

    final delta = _sensor.add(m);
    if (delta == null) return;

    _emit(delta);
    _publish(_state.copyWith(
      source: DistanceSource.sensor,
      speedMps: delta.speedMps,
      tunnelMeters: _state.tunnelMeters + delta.meters,
      axisConfidence: _axis.confidence,
    ));
  }

  /// Heartbeat. Detects dropouts (which by definition cannot be sample-driven)
  /// and pays out any in-flight reconciliation.
  void tick(DateTime now) {
    // A stalled inertial stream is only observable from the heartbeat, for the
    // same reason a stalled GPS stream is: a sample that never arrives cannot
    // report its own absence.
    if (_state.tunnelMode && _motionContinuous) {
      final last = _lastMotionAt;
      if (last == null ||
          now.difference(last) > AppConstants.motionContinuityGap) {
        _motionContinuous = false;
      }
    }

    _maybeEnterTunnel(now);

    final correction = _reconciler.take(now);
    if (correction > 0) {
      _emit(DistanceDelta.correction(
        timestamp: now,
        meters: correction,
        speedMps: _state.speedMps,
      ));
    }
    if (_state.reconciling != _reconciler.isActive) {
      _publish(_state.copyWith(reconciling: _reconciler.isActive));
    }
  }

  // ===========================================================================
  // Tunnel state machine
  // ===========================================================================

  MotionSample? _pendingMotion;

  /// SPEC-v2 §15.1 — enter Estimation Mode when ANY trigger fires.
  ///
  /// [degradedFix] carries the accuracy of a fix that has just arrived and been
  /// rejected, when there is one. That is the difference between the two
  /// triggers: the silence test can only fire from the heartbeat, because no
  /// incoming sample can announce that samples have stopped; the accuracy test
  /// can only fire from a sample, because silence carries no accuracy.
  void _maybeEnterTunnel(DateTime now, {double? degradedFixAccuracyM}) {
    if (_state.tunnelMode) return;

    // No prior good fix → nothing to anchor an estimate to. Wait, don't guess.
    final lastHealthy = _lastHealthyAt;
    if (lastHealthy == null) return;

    // §15.1: "No location update received for more than 3 seconds."
    if (now.difference(lastHealthy) >= AppConstants.tunnelConfirmDelay) {
      _enterTunnel(now);
      return;
    }

    // §15.1: "Reported horizontal accuracy is worse than 50 m." No waiting —
    // a fix this poor is worse than the estimate that would replace it, so
    // holding on to it for another three seconds only pollutes the trip.
    if (degradedFixAccuracyM != null &&
        degradedFixAccuracyM > AppConstants.estimationEntryAccuracyMeters) {
      _enterTunnel(now);
    }
  }

  void _enterTunnel(DateTime now) {
    // Only claim continuity if the stream is live RIGHT NOW. Entering a tunnel
    // on a device whose sensors were already silent must not inherit a trust we
    // never earned.
    final lastMotion = _lastMotionAt;
    _motionContinuous = lastMotion != null &&
        now.difference(lastMotion) <= AppConstants.motionContinuityGap;

    _tunnelEntryFix = _lastHealthySample;
    _tunnelEntrySpeedMps = _gpsSpeedMps;
    _sensor.seed(_gpsSpeedMps, _pendingMotion?.timestamp ?? now);
    _recoveryStreak = 0;
    _recoveryLast = null;

    _publish(_state.copyWith(
      source: DistanceSource.sensor,
      tunnelMode: true,
      tunnelSince: now,
      tunnelMeters: 0,
      axisConfidence: _axis.confidence,
    ));
  }

  /// SPEC-v2 §15.2 — leave Estimation Mode only when GNSS is genuinely back.
  ///
  ///   "Three consecutive fixes with horizontal accuracy of 20 m or better.
  ///    Those fixes are mutually consistent — each implies a plausible speed
  ///    relative to the previous one."
  ///
  /// Counting fixes rather than waiting out a duration is the whole point. A
  /// tunnel mouth throws out a burst of plausible-looking but wrong positions
  /// while the chip re-acquires; what makes a recovery trustworthy is that
  /// several fixes AGREE, not that time has passed. A timer would accept one
  /// fix on a 1 Hz chip and seven on a 5 Hz one for the same wall-clock wait.
  ///
  /// Any fix that fails either test resets the streak to zero rather than
  /// decrementing it, so a single bad fix mid-recovery restarts the count. That
  /// is the debouncing §15.2 asks for, and it is what stops the dashboard
  /// flickering between measured and estimated at the edge of coverage.
  void _maybeExitTunnel(GpsSample s, DateTime now) {
    if (s.accuracyM > AppConstants.estimationExitAccuracyMeters) {
      _recoveryStreak = 0;
      _recoveryLast = null;
      return;
    }

    final prev = _recoveryLast;
    if (prev != null && !_mutuallyConsistent(prev, s)) {
      // Restart the streak AT this fix: it may be the first honest one.
      _recoveryStreak = 1;
      _recoveryLast = s;
      return;
    }

    _recoveryStreak++;
    _recoveryLast = s;

    if (_recoveryStreak >= AppConstants.estimationExitConsecutiveFixes) {
      _exitTunnel(s, now);
    }
  }

  /// Whether [b] implies a plausible speed relative to [a] (SPEC-v2 §15.2).
  bool _mutuallyConsistent(GpsSample a, GpsSample b) {
    final dtMs = b.timestamp.difference(a.timestamp).inMilliseconds;
    if (dtMs <= 0) return false;

    final meters = GeoMath.distanceMeters(
      a.latitude,
      a.longitude,
      b.latitude,
      b.longitude,
    );
    if (!meters.isFinite) return false;

    return meters / (dtMs / 1000.0) <=
        AppConstants.estimationExitMaxImpliedSpeedMps;
  }

  void _exitTunnel(GpsSample exitFix, DateTime now) {
    // Re-anchor so the blackout chord is never integrated on top of the
    // estimate we already emitted for it.
    _gps.reanchor(exitFix);

    // Read the section's facts BEFORE anything clears them: the publish below
    // wipes tunnelSince and tunnelMeters.
    final start = _state.tunnelSince;
    final estimated = _state.tunnelMeters;

    final correction = _reconcileAgainst(exitFix, now);
    _logSection(start, now, estimated, correction);

    _sensor.reset();
    _tunnelEntryFix = null;
    _gpsSpeedMps = exitFix.speedMps.isFinite && exitFix.speedMps >= 0
        ? exitFix.speedMps
        : 0;

    _publish(_state.copyWith(
      source: DistanceSource.gps,
      tunnelMode: false,
      clearTunnelSince: true,
      speedMps: _gpsSpeedMps,
      reconciling: _reconciler.isActive,
    ));
  }

  /// Compare the estimate against what GPS can prove, and queue the shortfall.
  ///
  /// The comparison is against the straight-line chord from tunnel entry to
  /// exit. That chord is a strict LOWER BOUND on the road distance — a curved
  /// tunnel is always longer than the line through it — which drives the
  /// asymmetry here:
  ///
  ///  • Estimate BELOW the chord → provable undershoot. The car demonstrably
  ///    covered at least that much ground, so pay the difference out.
  ///  • Estimate ABOVE the chord → proves nothing. Any curve in the tunnel
  ///    makes this the expected result even for a perfect estimate, so
  ///    "correcting" down to the chord would systematically eat real distance.
  ///    We leave it alone.
  ///
  /// This is also why distance can never go backwards on recovery.
  ///
  /// Two sanity bounds decide whether the chord is evidence at all. A suspended
  /// app looks EXACTLY like a tunnel from here — fixes stop, then resume
  /// somewhere else — so without them, backgrounding the app for an hour of
  /// driving would reconcile the whole 50 km onto the trip counter.
  ///
  /// Returns the metres actually queued, which is what §15.3 logs as "the
  /// correction applied on recovery". Zero means the exit produced no usable
  /// evidence and the estimate stands as measured.
  double _reconcileAgainst(GpsSample exitFix, DateTime now) {
    final entry = _tunnelEntryFix;
    final since = _state.tunnelSince;
    if (entry == null || since == null) return 0;

    // 1. Too long to be a tunnel → almost certainly a suspension. The chord is
    //    real driving we never observed, not estimation error.
    // The cap depends on whether the inertial stream vouched for us. A car in
    // a tunnel keeps producing motion samples; a suspended app does not. Where
    // that evidence exists, a real tunnel is allowed to be long — Niayesh in
    // Tehran is 399 s at 60 km/h and Lærdal is 1102 s at 80, both of which the
    // old flat 5-minute cap silently refused to reconcile.
    final duration = now.difference(since);
    final cap = _motionContinuous
        ? AppConstants.maxTunnelDurationWithMotion
        : AppConstants.maxTunnelDuration;
    if (duration > cap) return 0;

    final chord = GeoMath.distanceMeters(
      entry.latitude,
      entry.longitude,
      exitFix.latitude,
      exitFix.longitude,
    );
    if (!chord.isFinite) return 0;

    // 2. Physically impossible for the time spent dark → a bad fix, not a
    //    tunnel. Mirrors the same 90 m/s guard the GPS source applies.
    final seconds = duration.inMilliseconds / 1000.0;
    if (seconds <= 0 || chord / seconds > 90.0) return 0;

    final residual = chord - _state.tunnelMeters;
    if (residual <= 0) return 0; // Overshoot proves nothing — see doc above.

    return _reconciler.add(residual, now);
  }

  /// SPEC-v2 §15.3 — record the section that just ended.
  ///
  /// Recorded unconditionally, including sections that were rejected for
  /// reconciliation. Those are the MOST interesting rows in a threshold-tuning
  /// log: a section with a long duration and a zero correction is how a
  /// suspended app or an overshooting estimate shows up, and dropping it would
  /// hide exactly the case the spec wants the data for.
  void _logSection(
    DateTime? start,
    DateTime end,
    double estimatedMeters,
    double correctionMeters,
  ) {
    // No start means the tunnel was never properly opened — nothing honest to
    // record about when it began, so record nothing at all.
    if (start == null) return;

    final section = EstimatedSection(
      start: start,
      end: end,
      estimatedMeters: estimatedMeters,
      heldSpeedMps: _tunnelEntrySpeedMps,
      correctionMeters: correctionMeters,
      largeCorrection: correctionMeters > 0 && _reconciler.isLarge,
    );
    _sections.add(section);
    onSection?.call(section);
  }

  // ===========================================================================
  // Internals
  // ===========================================================================

  /// Feed the axis estimator the one thing it can't get from the phone: the
  /// true sign of longitudinal acceleration, from GPS speed change.
  void _learnAxisFrom(GpsSample s) {
    final prev = _gps.anchor;
    final motion = _pendingMotion;
    if (prev == null || motion == null) return;

    final dtMs = s.timestamp.difference(prev.timestamp).inMilliseconds;
    if (dtMs <= 0 || dtMs > AppConstants.gpsStaleTimeout.inMilliseconds) return;
    if (!s.speedMps.isFinite || !prev.speedMps.isFinite) return;

    final gpsAccel = (s.speedMps - prev.speedMps) / (dtMs / 1000.0);
    _axis.observe(motion, gpsAccel);
  }

  void _noteMotion(DateTime now) {
    final last = _lastMotionAt;
    if (_state.tunnelMode &&
        last != null &&
        now.difference(last) > AppConstants.motionContinuityGap) {
      _motionContinuous = false;
    }
    _lastMotionAt = now;
  }

  void _emit(DistanceDelta d) {
    if (!d.meters.isFinite || d.meters < 0) return; // Never emit bad distance.
    onDelta(d);
  }

  void _publish(DistanceEngineState next) {
    _state = next;
    onState(next);
  }

  /// Start a fresh leg — clears every source's accumulated state.
  void reset() {
    _gps.reset();
    _sensor.reset();
    _axis.reset();
    _reconciler.reset();
    _lastHealthyAt = null;
    _recoveryStreak = 0;
    _recoveryLast = null;
    _lastHealthySample = null;
    _tunnelEntryFix = null;
    _tunnelEntrySpeedMps = 0;
    _lastMotionAt = null;
    _motionContinuous = false;
    _pendingMotion = null;
    _gpsSpeedMps = 0;
    // The §15.3 log belongs to the leg, like every other accumulated number
    // here. Keeping it across a reset would leave its totals spanning legs
    // while the trip counters restarted — two different meanings of "so far"
    // on the same screen.
    _sections.clear();
    _publish(DistanceEngineState.initial);
  }
}
