import 'dart:math' as math;

import '../../../core/constants/app_constants.dart';
import 'gps_sample.dart';

/// Processed, display-ready GPS state derived from raw fixes after smoothing.
/// Immutable so Riverpod `select` can cheaply diff individual fields.
class GpsState {
  const GpsState({
    required this.smoothedSpeedMps,
    required this.headingDeg,
    required this.accuracyM,
    required this.latitude,
    required this.longitude,
    required this.altitudeM,
    required this.quality,
    required this.receivedAt,
    required this.hasFix,
    this.streamError,
  });

  final double smoothedSpeedMps;
  final double headingDeg; // smoothed course over ground (NaN if unknown)
  final double accuracyM;
  final double latitude;
  final double longitude;
  final double altitudeM;
  final FixQuality quality;
  final DateTime receivedAt;
  final bool hasFix;

  /// Set when the position stream itself FAILED, as opposed to simply having
  /// nothing to report.
  ///
  /// These were previously dropped: the provider read `next.valueOrNull`, so an
  /// AsyncError became null and was skipped. That made a revoked permission, a
  /// dead sensor and a platform exception all indistinguishable from "no fix
  /// yet" — and a `0` meaning "the GPS is broken" looked exactly like a `0`
  /// meaning "the car is stopped".
  ///
  /// Null in the normal case, including inside a tunnel: silence is not an
  /// error.
  final String? streamError;

  /// Same state, tagged with a stream failure. Used by the provider so a broken
  /// receiver reads differently from a quiet one.
  GpsState copyWithError(String? error) => GpsState(
        smoothedSpeedMps: smoothedSpeedMps,
        headingDeg: headingDeg,
        accuracyM: accuracyM,
        latitude: latitude,
        longitude: longitude,
        altitudeM: altitudeM,
        quality: quality,
        receivedAt: receivedAt,
        hasFix: hasFix,
        streamError: error,
      );

  static GpsState initial() => GpsState(
        smoothedSpeedMps: 0,
        headingDeg: double.nan,
        accuracyM: -1,
        latitude: 0,
        longitude: 0,
        altitudeM: 0,
        quality: FixQuality.none,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(0),
        hasFix: false,
      );

  static FixQuality qualityFor(double accuracyM, bool hasFix) {
    if (!hasFix || accuracyM <= 0) return FixQuality.none;
    if (accuracyM <= AppConstants.goodAccuracyMeters) return FixQuality.good;
    if (accuracyM <= AppConstants.usableAccuracyMeters) return FixQuality.fair;
    return FixQuality.poor;
  }
}

/// Stateful exponential-moving-average filter for ground speed.
///
/// GPS speed is noisy near standstill; we floor sub-threshold speeds to zero
/// and EMA-smooth the rest so the big readout doesn't flicker.
///
/// ## The smoothing is TIME-based, not sample-based (SPEC-v2 §7.2, §19 row 3)
///
/// This used to apply a fixed per-sample weight. That makes the filter's lag a
/// property of whatever fix rate the chip happens to deliver: the same filter
/// was measured settling in **1.60 s on a 5 Hz stream and 8.00 s on a 1 Hz
/// one**, against §19's budget of **1.0 s**. §19 states the budget in seconds
/// and its own row 6 baselines the rate at 1 Hz — which is what most Android
/// GPS chips actually give (see `AppConstants.gpsInterval`) — so the slow case
/// was the normal case, and nothing was testing it.
///
/// Deriving the weight from the elapsed time instead
/// (`α = 1 − e^(−Δt/τ)`) makes the lag a property of the clock. A 5× change in
/// fix rate no longer changes how long the number takes to catch up.
///
/// **The trade-off is real and belongs to the spec, not to this filter.** At
/// 1 Hz a 1.0 s latency budget leaves very little room to smooth anything: the
/// weight works out near 1, so the display is close to pass-through. That is
/// §19 choosing "not slow" over "very stable" at low fix rates, and it is why
/// [AppConstants.gpsInterval] asking for 5 Hz matters — at 5 Hz there is
/// enough headroom to do both.
class SpeedFilter {
  double _value = 0;
  bool _seeded = false;
  DateTime? _lastAt;

  /// [at] is the fix's own timestamp. Optional so existing call sites and
  /// tests that only care about the value keep working; when omitted the
  /// filter falls back to one nominal interval per sample.
  double add(double rawMps, double accuracyM, [DateTime? at]) {
    // Reject obviously bad fixes — hold previous value rather than spike.
    if (rawMps.isNaN || rawMps < 0) return _value;

    final floored =
        rawMps < AppConstants.speedNoiseFloorMps ? 0.0 : rawMps;

    if (!_seeded) {
      _value = floored;
      _seeded = true;
      _lastAt = at;
      return _value;
    }

    final a = _weightFor(at);
    _value = a * floored + (1 - a) * _value;
    // Snap to exact zero once we've decayed close to it, so the display can
    // show a clean 0 when stopped.
    if (_value < 0.15) _value = 0;
    return _value;
  }

  /// The EMA weight for the interval ending at [at].
  ///
  /// A long gap (a dropout, a tunnel) yields a weight at or near 1, which is
  /// the right answer: after ten seconds of silence the old reading carries no
  /// information and holding on to it would be worse than showing the new fix.
  double _weightFor(DateTime? at) {
    final last = _lastAt;
    _lastAt = at;

    // No timestamps available — fall back to one nominal interval, which
    // reproduces the old behaviour exactly for callers that don't pass one.
    if (at == null || last == null) {
      return _alphaFor(AppConstants.gpsInterval);
    }
    final dt = at.difference(last);
    if (dt <= Duration.zero) return 0; // Out-of-order fix: hold, don't jump.
    return _alphaFor(dt);
  }

  static double _alphaFor(Duration dt) {
    final tau = AppConstants.speedSmoothingTau.inMicroseconds;
    if (tau <= 0) return 1;
    final a = 1 - math.exp(-dt.inMicroseconds / tau);
    return a.clamp(0.0, 1.0);
  }

  void reset() {
    _value = 0;
    _seeded = false;
    _lastAt = null;
  }
}
