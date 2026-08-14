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
  /// [instant] defaults to the app-wide switch. It is a parameter rather than a
  /// bare constant read so BOTH behaviours stay under test: the §16.1 smooth
  /// payout is still proven to work, which is what makes restoring the spec a
  /// one-line change with evidence behind it rather than a leap.
  DistanceReconciler({bool? instant})
      : _instant = instant ?? AppConstants.reconcileInstant;

  final bool _instant;

  double _remaining = 0;
  double _rate = 0; // metres per second
  DateTime? _lastAt;

  /// Whether a correction is still being paid out.
  bool get isActive => _remaining > 1e-3;

  /// Metres still owed.
  double get remainingMeters => _remaining;

  /// True while a correction large enough to need the §16.1 slow window is
  /// being paid out. "Flag the event in the trip log" — this is that flag.
  bool _large = false;
  bool get isLarge => _large;

  /// Queue a correction. Non-positive and negligible residuals are ignored.
  ///
  /// Adding while a payout is already in flight simply tops up the balance and
  /// re-derives the rate from the new total, so overlapping tunnels can't
  /// stack up unpaid corrections.
  ///
  /// Returns the metres actually accepted, so the §15.3 section log can report
  /// "the correction applied on recovery" without re-implementing this filter
  /// and drifting out of step with it.
  double add(double meters, DateTime now) {
    if (!meters.isFinite || meters < AppConstants.minReconcileMeters) return 0;

    _remaining += meters;
    _lastAt ??= now;

    // INSTANT MODE — a deliberate deviation from §16.1, see
    // [AppConstants.reconcileInstant] for who asked for it and what it costs.
    // An infinite rate makes the `min(_rate * dtSec, _remaining)` in [take]
    // resolve to the whole balance on the first tick with any elapsed time,
    // which reuses the existing payout path rather than adding a second one
    // that could drift out of step with it.
    if (_instant) {
      _large = _remaining > AppConstants.largeReconcileMeters;
      _rate = double.infinity;
      return meters;
    }

    // SPEC-v2 §16.1: 15 s normally, 60 s once the residual exceeds 200 m. The
    // test is on the RUNNING TOTAL, not the increment just added, so two
    // moderate corrections that stack into a large one are paid out at the
    // gentle rate rather than sneaking through at the fast one.
    _large = _remaining > AppConstants.largeReconcileMeters;
    final window =
        _large ? AppConstants.largeReconcileWindow : AppConstants.reconcileWindow;

    final windowSec = window.inMilliseconds / 1000.0;
    _rate = math.min(_remaining / windowSec, AppConstants.maxReconcileRateMps);
    return meters;
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
      _large = false;
      _lastAt = null;
    }
    return take;
  }

  /// Pay out everything still owed AT ONCE and clear.
  ///
  /// Used when the leg boundary moves under us — a trip reset. The outstanding
  /// balance is distance the vehicle ALREADY COVERED but has not been shown
  /// yet, so it belongs to the leg that is ending, not the one beginning. §16.1's
  /// "no visible jump" rule does not apply across a reset: the counter the
  /// driver is watching is about to be zeroed anyway.
  double settle() {
    final owed = _remaining;
    reset();
    return owed.isFinite && owed > 0 ? owed : 0.0;
  }

  void reset() {
    _remaining = 0;
    _rate = 0;
    _large = false;
    _lastAt = null;
  }
}
