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
///  4. Smooth, clamp to a plausible band, integrate to speed, then to distance.
///
/// ## Guarantees this source makes to the engine
///  • Distance is never negative and never decreases.
///  • Speed is clamped to `[0, cap]` — no spikes, no negative speed.
///  • Acceleration is clamped to ±[AppConstants.maxPlausibleAccelMps2] and
///    EMA-smoothed, so a pothole or a knocked mount cannot inject a jump.
///  • Sensor gaps (backgrounding) re-anchor instead of inventing distance.
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
  double _speedCap = 0;
  DateTime? _lastAt;
  bool _seeded = false;

  /// Current speed estimate (m/s).
  double get speedMps => _speedMps;

  bool get isSeeded => _seeded;

  /// Anchor the estimator to the last real GPS speed, at tunnel entry.
  ///
  /// The cap allows for genuine acceleration inside the tunnel while making a
  /// runaway integration impossible: even if every sample read maximum
  /// acceleration, the speed estimate cannot exceed this.
  void seed(double entrySpeedMps, DateTime at) {
    final v = entrySpeedMps.isFinite && entrySpeedMps > 0 ? entrySpeedMps : 0.0;
    _speedMps = v;
    _smoothedAccel = 0;
    _speedCap = math.max(v * 1.5, v + 8.0);
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

    // Integrate acceleration → speed, clamped so it can neither go negative
    // nor spike beyond what the entry speed makes plausible.
    _speedMps = (_speedMps + _smoothedAccel * dtSec).clamp(0.0, _speedCap);
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
    _speedCap = 0;
    _lastAt = null;
    _seeded = false;
  }
}
