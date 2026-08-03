import '../../../core/constants/app_constants.dart';
import '../../../core/utils/geo_math.dart';
import '../../gps/domain/gps_sample.dart';
import 'distance_delta.dart';

/// The primary distance source: ground distance between consecutive GPS fixes.
///
/// This is the single home of the rally-grade reliability rules that used to be
/// hand-copied between `TripController._onSample` and
/// `AverageSpeedCalculator.add` (kept in sync by comment, not by code):
///
///  • Only integrate usable fixes (has a fix, accuracy within
///    [AppConstants.usableAccuracyMeters]).
///  • Re-anchor without integrating across dropouts and out-of-order fixes, so
///    a blackout never inflates distance or elapsed time.
///  • Reject physically impossible jumps (teleports after a dropout).
///  • Report sub-[AppConstants.minMovementMeters] steps as ZERO movement rather
///    than dropping them — see below.
///
/// The zero-vs-null distinction is the contract both consumers depend on, and
/// it is what preserves their (correct, but different) stop behaviour:
///
///   • `null`                → the pair is unusable. Nothing happened: no
///                             distance, no time. Both consumers skip it.
///   • `meters == 0, dt > 0` → a real, accepted pair where the car did not
///                             move. The trip computer adds nothing; the
///                             average-speed integrator still accrues the time,
///                             so a running average correctly decays toward
///                             zero the longer you sit still.
///
/// Pure Dart — no plugin imports, no wall clock. Timing comes from the fix
/// timestamps, so replaying a log gives identical results.
class GpsDistanceSource {
  GpsSample? _last;

  /// The fix the next increment will be measured from (null before the first
  /// usable fix). Exposed so the engine can tell where the car was last
  /// genuinely seen — the anchor a tunnel is measured from.
  GpsSample? get anchor => _last;

  /// Whether [s] is trustworthy enough to integrate. Also the engine's
  /// definition of "GPS is healthy" for tunnel detection, so the source of
  /// truth for that judgement lives in exactly one place.
  static bool isHealthy(GpsSample s) =>
      s.hasFix &&
      s.accuracyM > 0 &&
      s.accuracyM <= AppConstants.usableAccuracyMeters;

  /// Fold a fix in, returning the increment it produced (see the class doc for
  /// the null-vs-zero contract).
  DistanceDelta? add(GpsSample s) {
    // Drop unusable fixes outright — never integrate noise.
    if (!isHealthy(s)) return null;

    final prev = _last;
    if (prev == null) {
      _last = s;
      return null; // First usable fix only anchors.
    }

    final dtMs = s.timestamp.difference(prev.timestamp).inMilliseconds;
    // Out-of-order, zero, or post-dropout gap → re-anchor without integrating.
    if (dtMs <= 0 ||
        dtMs > AppConstants.gpsStaleTimeout.inMilliseconds * 3) {
      _last = s;
      return null;
    }

    final meters = GeoMath.distanceMeters(
      prev.latitude,
      prev.longitude,
      s.latitude,
      s.longitude,
    );

    // Guard against NaN/inf positions and physically impossible teleports
    // (> ~324 km/h implies a bad fix, not real movement) — exclude entirely.
    if (!meters.isFinite) {
      _last = s;
      return null;
    }
    final impliedSpeed = meters / (dtMs / 1000.0);
    if (impliedSpeed > 90.0) {
      _last = s;
      return null;
    }

    _last = s;

    // Real movement only — anything under the floor is standstill jitter, and
    // is reported as an accepted pair that covered zero ground.
    final moved = meters >= AppConstants.minMovementMeters ? meters : 0.0;

    return DistanceDelta(
      timestamp: s.timestamp,
      meters: moved,
      dt: Duration(milliseconds: dtMs),
      speedMps: s.speedMps.isFinite && s.speedMps >= 0 ? s.speedMps : impliedSpeed,
      source: DistanceSource.gps,
    );
  }

  /// Move the anchor to [s] WITHOUT emitting an increment.
  ///
  /// Called when the car leaves a tunnel. The gap either side of the blackout
  /// has already been accounted for by the sensor estimate, so integrating the
  /// entry→exit chord here as well would double-count it. Short tunnels are
  /// exactly where this bites: the fix pair straddling a 5 s blackout is inside
  /// the [AppConstants.gpsStaleTimeout] window, so it would otherwise look like
  /// a perfectly ordinary — and very fast — increment.
  void reanchor(GpsSample s) => _last = s;

  /// Forget the anchor (start a fresh leg).
  void reset() => _last = null;
}
