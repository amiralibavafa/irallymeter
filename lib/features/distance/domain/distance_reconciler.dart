import 'dart:math' as math;

import '../../../core/constants/app_constants.dart';

/// Pays a post-tunnel GPS correction out gradually instead of snapping.
///
/// When GPS returns we usually find the sensor estimate undershot. Writing the
/// difference straight to the odometer would make the trip counter visibly jump
/// — the one thing a co-driver reading distances aloud must never see. So the
/// residual is drip-fed over [AppConstants.reconcileWindow] as ordinary small
/// increments, indistinguishable from normal driving.
///
/// Two independent limits apply, and the tighter one wins:
///  • spread the residual evenly across the window, and
///  • never exceed [AppConstants.maxReconcileRateMps] metres per second.
///
/// The rate ceiling is what makes "no visible jump" a guarantee rather than a
/// hope: a large residual simply takes longer to pay out than the nominal
/// window, instead of being crammed into it. A correction is only ever added,
/// never subtracted, so distance cannot go backwards mid-payout.
///
/// Pure Dart; the caller supplies the clock.
class DistanceReconciler {
  double _remaining = 0;
  double _rate = 0; // metres per second
  DateTime? _lastAt;

  /// Whether a correction is still being paid out.
  bool get isActive => _remaining > 1e-3;

  /// Metres still owed.
  double get remainingMeters => _remaining;

  /// Queue a correction. Non-positive and negligible residuals are ignored.
  ///
  /// Adding while a payout is already in flight simply tops up the balance and
  /// re-derives the rate from the new total, so overlapping tunnels can't
  /// stack up unpaid corrections.
  void add(double meters, DateTime now) {
    if (!meters.isFinite || meters < AppConstants.minReconcileMeters) return;

    _remaining += meters;
    _lastAt ??= now;

    final windowSec = AppConstants.reconcileWindow.inMilliseconds / 1000.0;
    _rate = math.min(_remaining / windowSec, AppConstants.maxReconcileRateMps);
  }

  /// Metres to emit for the interval ending at [now]. Returns 0 when idle.
  double take(DateTime now) {
    if (!isActive) return 0;

    final last = _lastAt;
    if (last == null) {
      _lastAt = now;
      return 0;
    }

    final dtSec = now.difference(last).inMicroseconds / Duration.microsecondsPerSecond;
    if (dtSec <= 0) return 0;
    _lastAt = now;

    final take = math.min(_rate * dtSec, _remaining);
    _remaining -= take;

    if (!isActive) {
      // Settle exactly, so a float tail can't leave the reconciler half-active.
      _remaining = 0;
      _rate = 0;
      _lastAt = null;
    }
    return take;
  }

  void reset() {
    _remaining = 0;
    _rate = 0;
    _lastAt = null;
  }
}
