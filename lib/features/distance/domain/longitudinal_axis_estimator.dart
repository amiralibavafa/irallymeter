import '../../../core/constants/app_constants.dart';
import 'motion_sample.dart';

/// Learns which way the car points, expressed in the phone's own axes.
///
/// ## Why this exists
///
/// Inside a tunnel we can measure how hard the car is accelerating, but not
/// whether it is speeding up or slowing down. The accelerometer reports a
/// vector in the DEVICE frame, and a phone in a dash mount sits at an arbitrary
/// yaw — so "+2 m/s² along the phone's Y axis" could mean braking or throttle
/// depending on which way the mount happens to face. Magnitude alone is
/// sign-blind, and integrating a sign-blind acceleration is worse than useless:
/// it turns every brake into an acceleration.
///
/// ## How it works
///
/// While GPS is healthy we have both halves of the answer: the horizontal
/// acceleration direction (from the phone) and its true sign (from GPS dv/dt).
/// Every time the car meaningfully accelerates or brakes we take the unit
/// horizontal acceleration direction, flip it to point FORWARD using the GPS
/// sign, and fold it into a running EMA.
///
/// Braking pushes the phone one way, accelerating pushes it exactly the other —
/// so once sign-corrected, both events vote for the same forward direction and
/// the EMA converges on it. Readings driven by noise, potholes or cornering
/// point in inconsistent directions and cancel out instead.
///
/// That cancellation is what makes [confidence] self-validating: because we
/// average UNIT vectors, the result's length is itself the agreement measure.
/// Consistent votes → length approaches 1. Noise → length approaches 0. No
/// separate quality heuristic is needed, and the estimator cannot claim
/// confidence it has not earned.
///
/// The axis is learned continuously in clear air so it is ready the instant the
/// tunnel arrives — learning it once inside would be far too late.
///
/// Pure Dart, no wall clock: fully unit-testable.
class LongitudinalAxisEstimator {
  Vec3 _axis = Vec3.zero;

  /// Current forward direction in the device frame, or null while unlearned.
  Vec3? get forward => _axis.normalized();

  /// Agreement among the samples seen so far, 0..1 — see the class doc for why
  /// this is simply the mean vector's length.
  double get confidence => _axis.length.clamp(0.0, 1.0);

  /// True once the axis is trustworthy enough to resolve a sign with.
  bool get isConfident => confidence >= AppConstants.minAxisConfidence;

  /// Fold in one observation.
  ///
  /// [gpsAccelMps2] is the true longitudinal acceleration from GPS speed change
  /// — the sign teacher. Samples with no usable acceleration signal are
  /// ignored, because a unit direction derived from near-zero acceleration is
  /// just amplified noise and would dilute the estimate.
  void observe(MotionSample m, double gpsAccelMps2) {
    if (!m.isUsable || !gpsAccelMps2.isFinite) return;
    if (gpsAccelMps2.abs() < AppConstants.axisMinAccelSignal) return;

    final down = m.gravity.normalized();
    if (down == null) return;

    // Strip the vertical component — road bumps carry no heading information.
    final horizontal = m.userAccel.rejectFrom(down).normalized();
    if (horizontal == null) return;

    // Point the observation forward, then average it in.
    final vote = horizontal * (gpsAccelMps2.isNegative ? -1.0 : 1.0);
    const a = AppConstants.axisLearningRate;
    _axis = _axis * (1 - a) + vote * a;
  }

  void reset() => _axis = Vec3.zero;
}
