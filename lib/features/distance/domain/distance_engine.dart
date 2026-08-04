import '../../../core/constants/app_constants.dart';
import '../../../core/utils/geo_math.dart';
import '../../gps/domain/gps_sample.dart';
import 'distance_delta.dart';
import 'distance_engine_state.dart';
import 'distance_reconciler.dart';
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
///   3. [DistanceSource.manual] — driver override. Forces Tunnel Mode on while
///      a manual tunnel is being recorded, so the driver's judgement outranks
///      the automatic detector (see [setManualTunnel]).
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
  DistanceEngine({required this.onDelta, required this.onState});

  /// Emits every distance increment, whatever its source.
  final void Function(DistanceDelta) onDelta;

  /// Emits whenever the engine's observable state changes.
  final void Function(DistanceEngineState) onState;

  final GpsDistanceSource _gps = GpsDistanceSource();
  final LongitudinalAxisEstimator _axis = LongitudinalAxisEstimator();
  late final SensorDistanceSource _sensor = SensorDistanceSource(_axis);
  final DistanceReconciler _reconciler = DistanceReconciler();

  DistanceEngineState _state = DistanceEngineState.initial;
  DistanceEngineState get state => _state;

  // --- GPS health tracking (wall clock — see class doc) ---
  DateTime? _lastHealthyAt;
  GpsSample? _lastHealthySample;
  bool _lastSampleHealthy = false;
  double _gpsSpeedMps = 0;

  // --- Tunnel bookkeeping ---
  GpsSample? _tunnelEntryFix;
  bool _manualTunnel = false;

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
    _lastSampleHealthy = healthy;

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

  /// Driver override: the manual source's role in the priority chain.
  ///
  /// Deliberately does NOT force estimation on. GPS is primary, and a sensor
  /// estimate is never better than a healthy fix — so marking a tunnel while
  /// the signal is still good keeps integrating GPS. Doing otherwise would
  /// throw away ground truth in exchange for dead reckoning, which is strictly
  /// worse and would make the measured leg less accurate, not more.
  ///
  /// What it DOES buy is latency. A tunnel mouth usually degrades accuracy
  /// before the signal vanishes, and the driver can see it coming; their
  /// assertion lets us start estimating the moment GPS stops being usable,
  /// instead of waiting out [AppConstants.tunnelConfirmDelay] of junk fixes.
  ///
  /// Recording is otherwise orthogonal to source arbitration: if GPS recovers
  /// mid-tunnel we go straight back to it while the leg keeps measuring.
  void setManualTunnel(bool active, DateTime now) {
    if (_manualTunnel == active) return;
    _manualTunnel = active;

    if (active && !_state.tunnelMode && !_gpsUsableNow(now)) {
      _enterTunnel(now);
    }
    _publish(_state.copyWith(manualTunnel: active));
  }

  /// Whether GPS is delivering fixes we would actually integrate right now.
  ///
  /// Both halves matter: the last fix must have been good (accuracy hasn't
  /// collapsed at the tunnel mouth) AND fixes must still be arriving. Checking
  /// only staleness would make the manual override useless, since the stale
  /// timeout is longer than the auto-confirm delay it is meant to pre-empt.
  bool _gpsUsableNow(DateTime now) {
    final last = _lastHealthyAt;
    return _lastSampleHealthy &&
        last != null &&
        now.difference(last) < AppConstants.gpsStaleTimeout;
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
    _tunnelEntryFix = _lastHealthySample;
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

    _reconcileAgainst(exitFix, now);

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
  void _reconcileAgainst(GpsSample exitFix, DateTime now) {
    final entry = _tunnelEntryFix;
    final since = _state.tunnelSince;
    if (entry == null || since == null) return;

    // 1. Too long to be a tunnel → almost certainly a suspension. The chord is
    //    real driving we never observed, not estimation error.
    final duration = now.difference(since);
    if (duration > AppConstants.maxTunnelDuration) return;

    final chord = GeoMath.distanceMeters(
      entry.latitude,
      entry.longitude,
      exitFix.latitude,
      exitFix.longitude,
    );
    if (!chord.isFinite) return;

    // 2. Physically impossible for the time spent dark → a bad fix, not a
    //    tunnel. Mirrors the same 90 m/s guard the GPS source applies.
    final seconds = duration.inMilliseconds / 1000.0;
    if (seconds <= 0 || chord / seconds > 90.0) return;

    final residual = chord - _state.tunnelMeters;
    if (residual <= 0) return; // Overshoot proves nothing — see doc above.

    _reconciler.add(residual, now);
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
    _pendingMotion = null;
    _gpsSpeedMps = 0;
    _manualTunnel = false;
    _publish(DistanceEngineState.initial);
  }
}
