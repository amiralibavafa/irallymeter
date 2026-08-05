import 'dart:math' as math;

import '../../../core/constants/app_constants.dart';
import 'distance_delta.dart';
import 'longitudinal_axis_estimator.dart';
import 'motion_sample.dart';

/// The fallback distance source: dead-reckoning from phone motion sensors,
/// used only while GPS is unavailable.
///
/// ## The model, and why it is this conservative
///
/// Double-integrating a phone accelerometer into a position is a known dead
/// end — the error grows with the SQUARE of time, so a raw integration is
/// metres out within seconds and hundreds of metres out within a minute. It is
/// not a tuning problem; it is what the sensor is.
///
/// So this does not estimate position. It estimates SPEED, anchored to the real
/// GPS speed measured at the moment the car entered the tunnel, and integrates
/// that speed to distance. Error then grows only LINEARLY with time, and the
/// dominant physical fact — a car in a tunnel is holding roughly the speed it
/// entered at — is the model's starting point rather than something the
/// integration has to rediscover from noise.
///
/// Concretely, per sample:
///  1. Strip gravity's axis out of the acceleration → horizontal only.
///  2. Remove the cornering component. A turn produces centripetal
///     acceleration `v·ω` perpendicular to travel; without this step every
///     bend would read as hard acceleration. The yaw rate ω comes from the
///     gyroscope about the gravity axis, so this works at any mount angle.
///  3. Resolve the SIGN from the pre-learned forward axis
///     ([LongitudinalAxisEstimator]). If the axis was never learned
///     confidently, assume zero acceleration — i.e. coast at the entry speed.
///     That is the honest answer: a sign-blind acceleration is worse than none,
///     since it would read every brake as a throttle.
///  4. Smooth, integrate to speed, bound the result to ±25% of v₀ per
///     SPEC-v2 §12.2, then integrate speed to distance.
///
/// ## Guarantees this source makes to the engine
///  • Distance is never negative and never decreases.
///  • Speed never rises more than 25% above the entry speed v₀ (§12.2), and is
///    never negative. The bound is on TOTAL drift from v₀, not per sample, so
///    many small nudges cannot walk the estimate somewhere a single step would
///    have been refused.
///  • Acceleration is clamped to ±[AppConstants.maxPlausibleAccelMps2] and
///    EMA-smoothed, so a pothole or a knocked mount cannot inject a jump.
///  • Sensor gaps (backgrounding) re-anchor instead of inventing distance.
///
/// ## The one deviation from §12.2, and why
///
/// §12.2 reads as a symmetric ±25% band. This applies it UPWARDS ONLY;
/// deceleration may run to a full stop. Symmetric, a car braking to a halt in a
/// tunnel would hold v₀ and invent distance for as long as it sat there.
///
/// The asymmetry follows the risk, not convenience. An over-estimate is
/// PERMANENT — [DistanceEngine] only reconciles undershoot, because an estimate
/// above the entry→exit chord "proves nothing" — so it corrupts every distance
/// called after it. An under-estimate is recoverable on the next good fix. And
/// what §12.2 defends against is a runaway integration, which is an upward
/// failure; a sustained deceleration is the most reliable reading an
/// accelerometer produces.
///
/// It is an estimate and is treated as one: the engine reconciles it against
/// GPS truth the moment the car comes back into the open.
///
/// Pure Dart — no plugin imports, no wall clock.
class SensorDistanceSource {
  SensorDistanceSource(this._axis);

  final LongitudinalAxisEstimator _axis;

  double _speedMps = 0;
  double _smoothedAccel = 0;

  /// v₀ — the real GPS speed measured at tunnel entry, and the anchor the whole
  /// §12.1 model rests on.
  double _entrySpeedMps = 0;

  /// ±25% of v₀ (SPEC-v2 §12.2), precomputed at seed time.
  double _maxAdjustMps = 0;

  DateTime? _lastAt;
  bool _seeded = false;

  /// Current speed estimate (m/s).
  double get speedMps => _speedMps;

  bool get isSeeded => _seeded;

  /// Anchor the estimator to the last real GPS speed, at tunnel entry.
  ///
  /// v₀ is the whole model. SPEC-v2 §12.1 holds it and accumulates `v₀ × Δt`;
  /// §12.2's accelerometer refinement may only nudge the estimate a bounded
  /// distance either side of it.
  void seed(double entrySpeedMps, DateTime at) {
    final v = entrySpeedMps.isFinite && entrySpeedMps > 0 ? entrySpeedMps : 0.0;
    _speedMps = v;
    _entrySpeedMps = v;
    _smoothedAccel = 0;
    _maxAdjustMps = v * AppConstants.maxSpeedAdjustFraction;
    _lastAt = at;
    _seeded = true;
  }

  /// Fold in a motion sample, returning the distance it produced. Returns null
  /// when the sample cannot be used (not seeded, unusable, or after a gap).
  DistanceDelta? add(MotionSample m) {
    if (!_seeded || !m.isUsable) return null;

    final last = _lastAt;
    if (last == null) {
      _lastAt = m.timestamp;
      return null;
    }

    final dtMs = m.timestamp.difference(last).inMilliseconds;
    // Out-of-order or a stalled stream → re-anchor time, invent no distance.
    if (dtMs <= 0 || dtMs > AppConstants.motionMaxGap.inMilliseconds) {
      _lastAt = m.timestamp;
      return null;
    }
    _lastAt = m.timestamp;
    final dtSec = dtMs / 1000.0;

    _smoothedAccel = _blend(_smoothedAccel, _longitudinalAccel(m));

    // Integrate acceleration → speed, then apply SPEC-v2 §12.2:
    //
    //   "Clamp the total adjustment to ±25% of v₀. If the correction wants to
    //    exceed this, ignore it and hold v₀."
    //
    // Note "the total adjustment", not the per-sample one: the bound is on how
    // far the estimate has drifted from the entry speed overall, so a long
    // sequence of small, plausible nudges cannot walk the estimate anywhere it
    // could not have jumped in one step.
    //
    // Replaces a `max(v*1.5, v + 8.0)` ceiling — +50%, or +28.8 km/h at low
    // speed, and an upper bound only with no floor at all.
    //
    // Integrate acceleration → speed, bounded by SPEC-v2 §12.2's ±25% of v₀.
    //
    // SATURATES at the ceiling rather than snapping back to v₀. §12.2's "if the
    // correction wants to exceed this, ignore it and hold v₀" can be read as a
    // snap-back, but implemented that way the estimate sawtooths — climbing to
    // the ceiling, dropping to v₀, climbing again. On an instrument that shows
    // estimated speed to the driver (§5.1) that reads as a fault, and it is
    // also further from the truth than saturating: a car genuinely accelerating
    // through a tunnel is better approximated by the ceiling than by an average
    // of the ceiling and the entry speed. "Clamp" is the plain reading.
    //
    // Applied UPWARDS ONLY; deceleration runs to a full stop. The asymmetry
    // follows the risk. An over-estimate is PERMANENT, because
    // `DistanceEngine._reconcileAgainst` pays out undershoot only — an estimate
    // above the entry→exit chord "proves nothing" — so it corrupts every
    // distance called after it. An under-estimate is recoverable on the next
    // good fix. And what §12.2 defends against is a runaway integration, which
    // is an upward failure; a sustained deceleration is the most reliable
    // reading an accelerometer produces, and `tunnel_system_test.dart` test 11
    // already asserts a clean stop must be believed.
    _speedMps = (_speedMps + _smoothedAccel * dtSec)
        .clamp(0.0, _entrySpeedMps + _maxAdjustMps);

    // Reuse the GPS noise floor so a crawl decays to a clean stop rather than
    // creeping distance forever.
    if (_speedMps < AppConstants.speedNoiseFloorMps) _speedMps = 0;

    // Integrate speed → distance. Non-negative by construction.
    final meters = _speedMps * dtSec;

    return DistanceDelta(
      timestamp: m.timestamp,
      meters: meters,
      dt: Duration(milliseconds: dtMs),
      speedMps: _speedMps,
      source: DistanceSource.sensor,
      // The estimator zeroes its speed below the noise floor (just above), so
      // a non-zero speed here IS its verdict that the car is still moving. It
      // needs no floor of its own, and giving it one would let the two sources
      // disagree about what counts as a stop inside the same tunnel.
      moving: _speedMps > 0,
    );
  }

  /// Longitudinal (along-travel) acceleration in m/s², already clamped to the
  /// plausible band. Returns 0 — coast — whenever the sign cannot be trusted.
  double _longitudinalAccel(MotionSample m) {
    final down = m.gravity.normalized();
    if (down == null) return 0;

    // Horizontal acceleration: what the car did, minus what the road did.
    final horizontal = m.userAccel.rejectFrom(down);
    final aMag = horizontal.length;
    if (!aMag.isFinite || aMag <= 0) return 0;

    // Cornering removal. Yaw rate about the gravity axis gives the centripetal
    // component v·ω, which is perpendicular to travel; what remains is
    // longitudinal. Pythagoras, floored at zero so sensor noise making the
    // lateral estimate exceed the total can't produce a NaN.
    final omega = m.gyro.dot(down).abs();
    final aLat = _speedMps * omega;
    final aLon = math.sqrt(math.max(0.0, aMag * aMag - aLat * aLat));

    // Sign resolution — the whole reason the forward axis is learned in advance.
    final forward = _axis.forward;
    if (forward == null || !_axis.isConfident) return 0; // coast.

    final signed = horizontal.dot(forward).isNegative ? -aLon : aLon;

    return signed.clamp(
      -AppConstants.maxPlausibleAccelMps2,
      AppConstants.maxPlausibleAccelMps2,
    );
  }

  double _blend(double prev, double next) {
    const a = AppConstants.sensorAccelSmoothing;
    return a * next + (1 - a) * prev;
  }

  void reset() {
    _speedMps = 0;
    _smoothedAccel = 0;
    _entrySpeedMps = 0;
    _maxAdjustMps = 0;
    _lastAt = null;
    _seeded = false;
  }
}
