import 'dart:math' as math;

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

  /// When the current unbroken run of merely USABLE fixes began, and the last
  /// fix in it. Every fix that reaches [_maybeExitTunnel] is already healthy, so
  /// this run is what breaks the 21-25 m latch — see
  /// [AppConstants.estimationExitUsableWindow].
  DateTime? _usableSince;
  GpsSample? _usableLast;
  DateTime? _usableLastAt;

  /// The first usable fix of the current recovery run — where the genuinely
  /// DARK stretch ended. From here the engine measures from real fixes instead
  /// of dead-reckoning, and the stretch is reconciled against THIS fix rather
  /// than the eventual exit one.
  ///
  /// Without that, provisional measuring would double-count: the chord to the
  /// exit fix spans ground the engine had already measured metre by metre.
  GpsSample? _darkEndFix;

  /// True while usable fixes are flowing but §15.2 has not confirmed recovery.
  /// The sensor estimate is SUSPENDED here — see [_maybeExitTunnel].
  bool _measuringWhileEstimating = false;

  // ===========================================================================
  // Inputs
  // ===========================================================================

  /// Fold in a GPS fix. [now] is wall-clock; the fix carries its own timestamp.
  void onGpsSample(GpsSample s, DateTime now) {
    final healthy = GpsDistanceSource.isHealthy(s);

    if (!healthy) {
      // An unhealthy fix is indistinguishable from no fix for our purposes:
      // don't refresh the health clock, and drop both recovery runs. The
      // usable run especially: it exists to prove the signal came BACK, and a
      // fix we would refuse to integrate is not evidence of that.
      _recoveryStreak = 0;
      _recoveryLast = null;
      if (_state.tunnelMode) {
        _breakUsableRun(now);
      } else {
        _usableSince = null;
        _usableLast = null;
        _usableLastAt = null;
      }
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

    // PROVISIONAL MEASURING (Codex CODEX-2). While usable fixes are arriving the
    // engine measures from them instead of dead-reckoning, so the estimate must
    // not also run — otherwise the same ground is counted twice, and an
    // over-count is permanent because `_reconcileAgainst` pays undershoot only.
    // The sensor is still fed below via `_sensor.add` being skipped, and it is
    // re-seeded from the last real speed if the fixes stop again.
    if (_measuringWhileEstimating) return;

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
    _usableSince = null;
    _usableLast = null;
    _usableLastAt = null;
    _darkEndFix = null;
    _measuringWhileEstimating = false;

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
  /// There is a SECOND exit, and without it the first one latches.
  ///
  /// Every fix reaching this method is already healthy — [onGpsSample] sent the
  /// rest away — which means it is a fix the engine would integrate as ground
  /// truth if it were not in Estimation Mode. But healthy means 25 m
  /// ([AppConstants.usableAccuracyMeters]) and §15.2's exit bar is 20 m, so a
  /// fix in the 21-25 m band can neither be measured with NOR escaped with, and
  /// nothing else ends the mode. The engine dead-reckons from v0 while usable
  /// truth streams past it, for as long as the band persists.
  ///
  /// So a sustained run of usable, mutually consistent fixes also ends the mode
  /// (see [AppConstants.estimationExitUsableWindow]). §15.2 is untouched: three
  /// fixes at 20 m or better still exit immediately. This decides only what
  /// happens when those never come.
  void _maybeExitTunnel(GpsSample s, DateTime now) {
    // Track the usable run first, so it survives fixes that fail the 20 m bar.
    //
    // The run restarts on either kind of break. Inconsistency is the obvious
    // one. The other is a GAP: usable fixes arriving further apart than
    // [AppConstants.tunnelConfirmDelay] are not a recovered signal, they are a
    // signal still dropping out — that same gap is what §15.1 uses to declare a
    // tunnel in the first place, so it cannot also count as evidence of leaving
    // one. Without this, two lone fixes ten seconds apart would end the mode.
    final prevUsable = _usableLast;
    final prevUsableAt = _usableLastAt;
    final broken = prevUsable != null &&
        (!_mutuallyConsistent(prevUsable, s) ||
            prevUsableAt == null ||
            now.difference(prevUsableAt) > AppConstants.tunnelConfirmDelay);
    if (broken) {
      _breakUsableRun(now); // the run restarts at this fix
    }
    if (_usableSince == null) {
      // FIRST usable fix of this run: the dark stretch ends HERE.
      //
      // From this point the engine MEASURES rather than dead-reckons, which is
      // Codex's provisional-measuring fix. Estimation Mode stays on — §15.2 has
      // not confirmed anything yet and the display must keep saying EST — but
      // the number behind it is now real, so there is nothing to take back if
      // the fixes turn out to be a tunnel-mouth burst and the run breaks.
      _usableSince = now;
      _darkEndFix = s;
      _measuringWhileEstimating = true;
      _gps.reanchor(s); // anchor only; emits nothing

      // SETTLE THE DARK STRETCH HERE, not at exit. This fix is where the
      // blackout ended; everything after it is measured. Reconciling later
      // would compare the estimate against a chord spanning ground already
      // counted, and settling never would silently DISCARD the estimate if the
      // run then broke — which is exactly what cost T3 and S3 3.8 % and 8.2 %.
      _settleDarkStretch(s, now);
    }
    _usableLast = s;
    _usableLastAt = now;

    // Measure from this fix. `_gps.add` applies the whole §6.1 gate, so a
    // 21-25 m fix contributes exactly what it would outside a tunnel.
    if (_measuringWhileEstimating) {
      final delta = _gps.add(s);
      if (delta != null) {
        _gpsSpeedMps = delta.speedMps;
        _emit(delta);
        _publish(_state.copyWith(speedMps: delta.speedMps));
      }
    }

    if (s.accuracyM <= AppConstants.estimationExitAccuracyMeters) {
      final prev = _recoveryLast;
      if (prev != null && !_mutuallyConsistent(prev, s)) {
        // Restart the streak AT this fix: it may be the first honest one.
        _recoveryStreak = 1;
        _recoveryLast = s;
      } else {
        _recoveryStreak++;
        _recoveryLast = s;
        if (_recoveryStreak >= AppConstants.estimationExitConsecutiveFixes) {
          _exitTunnel(s, now);
          return;
        }
      }
    } else {
      _recoveryStreak = 0;
      _recoveryLast = null;
    }

    // The sustained-usable exit. It no longer costs anything: the window is
    // spent MEASURING, not coasting, so waiting it out cannot invent distance.
    // That is what makes it safe to keep alongside §15.2 rather than a
    // deviation from it — §15.2 still decides when the display stops saying
    // EST, and three fixes at 20 m still do that immediately.
    final since = _usableSince;
    if (since != null &&
        now.difference(since) >= AppConstants.estimationExitUsableWindow) {
      _exitTunnel(s, now);
    }
  }

  /// Reconcile and log the blackout that just ended, then zero the estimate.
  ///
  /// Called once per dark stretch, at the moment real fixes take over. A tunnel
  /// with a usable patch in the middle is therefore two stretches, each
  /// reconciled against its own chord, rather than one stretch whose estimate is
  /// compared to a chord it never covered.
  void _settleDarkStretch(GpsSample darkEnd, DateTime at) {
    final start = _state.tunnelSince;
    final estimated = _state.tunnelMeters;
    if (start == null) return;

    final correction = _reconcileAgainst(darkEnd, at);
    _logSection(start, at, estimated, correction);

    _sensor.reset();
    _publish(_state.copyWith(
      tunnelSince: at,
      tunnelMeters: 0,
      reconciling: _reconciler.isActive,
    ));
  }

  /// The usable run broke: go back to dead-reckoning from the last real speed.
  ///
  /// Nothing measured is discarded — it was ground truth. Only the ANCHOR is
  /// dropped, so the next dark stretch is reconciled against where the car
  /// actually was when the signal died, not where it entered the first tunnel.
  void _breakUsableRun(DateTime now) {
    _usableSince = null;
    _usableLast = null;
    _usableLastAt = null;
    if (_measuringWhileEstimating) {
      // The stretch that just ended was settled at dark-end, and everything
      // since was measured. So this only OPENS a new dark stretch: anchor it at
      // the last fix we trusted and re-seed the estimate from the speed that
      // fix reported, rather than the one we entered the first tunnel at.
      _tunnelEntryFix = _gps.anchor ?? _darkEndFix ?? _tunnelEntryFix;
      _tunnelEntrySpeedMps = _gpsSpeedMps;
      _sensor.seed(_gpsSpeedMps, _pendingMotion?.timestamp ?? now);
      _publish(_state.copyWith(tunnelSince: now, tunnelMeters: 0));
    }
    _measuringWhileEstimating = false;
    _darkEndFix = null;
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

    // NOTHING is reconciled here any more. The dark stretch was settled the
    // moment real fixes took over (`_settleDarkStretch`), and every metre since
    // has been measured and already emitted. Reconciling again would compare an
    // estimate of zero against a chord the engine had counted metre by metre,
    // and queue the whole thing a second time.
    //
    // The only case with no dark-end is a mode that never saw a usable fix, and
    // that cannot reach here: exiting requires healthy fixes.
    if (_darkEndFix == null) _settleDarkStretch(exitFix, now);

    _sensor.reset();
    _tunnelEntryFix = null;
    _usableSince = null;
    _usableLast = null;
    _usableLastAt = null;
    _darkEndFix = null;
    _measuringWhileEstimating = false;
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

    // 2. Faster than the car itself says it was going → a DISPLACED fix, not a
    //    tunnel.
    //
    // This used to be a flat 90 m/s, which does not guard the case that
    // matters. A receiver leaving a tunnel can reacquire as a stable cluster
    // hundreds of metres off the true path: those fixes agree with EACH OTHER,
    // so `_mutuallyConsistent` passes them, and a 1 km chord after a 25 s
    // blackout implies 40 m/s — comfortably under 90. The entire false residual
    // was then queued, and a residual is never given back.
    //
    // The car's own Doppler speeds at entry and exit are the evidence that
    // check threw away. A vehicle that went in at 20 m/s and came out at 20 m/s
    // did not average 40 m/s in between.
    final seconds = duration.inMilliseconds / 1000.0;
    if (seconds <= 0) return 0;

    final impliedMps = chord / seconds;
    final endpoint = math.max(
      _tunnelEntrySpeedMps.isFinite ? _tunnelEntrySpeedMps : 0.0,
      exitFix.speedMps.isFinite && exitFix.speedMps >= 0 ? exitFix.speedMps : 0.0,
    );
    final plausibleMps = endpoint * AppConstants.maxRecoveryChordSpeedFactor +
        AppConstants.maxRecoveryChordSpeedMarginMps;
    // The absolute ceiling still applies, so a pair of nonsense endpoint speeds
    // cannot license an arbitrarily long chord.
    if (impliedMps > math.min(plausibleMps, 90.0)) return 0;

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

  /// Pay out any correction still owed, immediately, and report the metres.
  ///
  /// Called when the driver resets a trip counter. Without this the reconciler
  /// keeps drip-feeding the old leg's distance into the NEW leg: measured at up
  /// to 715 m in `phase3_completeness_test`, which on a rally is the difference
  /// between "turn after 3 km" landing on the right junction and the wrong one.
  ///
  /// Returns the metres rather than emitting them, deliberately. The delta
  /// stream is asynchronous, so emitting here and zeroing the counter in the
  /// caller would race — the delta would land AFTER the reset and reintroduce
  /// exactly the bug being fixed. The caller applies these metres to the
  /// counters it is not clearing.
  double settleReconciliation(DateTime now) {
    final owed = _reconciler.settle();
    if (_state.reconciling) _publish(_state.copyWith(reconciling: false));
    return owed;
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
    _usableSince = null;
    _usableLast = null;
    _usableLastAt = null;
    _darkEndFix = null;
    _measuringWhileEstimating = false;
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
