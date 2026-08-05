import '../../distance/domain/distance_delta.dart';
import '../../distance/domain/gps_distance_source.dart';
import '../../gps/domain/gps_sample.dart';

/// Rolling average-speed integrator, in the style of a professional rally trip
/// meter: average = accumulated ground distance ÷ accumulated travel time.
///
/// Pure Dart (no plugin imports) so it is fully unit-testable.
///
/// ## Where its data comes from
///
/// This folds in [DistanceDelta]s from the distance engine, so it averages over
/// GPS distance in the open AND sensor-estimated distance inside a tunnel — the
/// average keeps integrating through a blackout instead of freezing. The
/// reliability rules it used to hand-implement (accuracy gating, dropout
/// re-anchoring, teleport rejection, the min-movement floor) now live once in
/// [GpsDistanceSource], which is what keeps this and the trip computer in
/// agreement by construction rather than by comment.
///
/// ## Stop/pause handling
///
/// Between two accepted, in-window fixes the **time always accrues**, but
/// **distance only accrues for real movement**. So while the car is stationary
/// the distance is frozen while time keeps ticking — exactly like a real trip
/// meter, the running average decays toward zero the longer you sit still.
/// Corrections carry no time of their own ([DistanceDelta.dt] is zero), so
/// reconciling a tunnel adds its distance without inflating elapsed time and
/// skewing the average.
class AverageSpeedCalculator {
  double _distanceMeters = 0;
  Duration _elapsed = Duration.zero;
  Duration _movingElapsed = Duration.zero;

  /// Backs the raw-fix [add] entry point only — see its doc.
  final GpsDistanceSource _gps = GpsDistanceSource();

  /// Total integrated ground distance (metres).
  double get distanceMeters => _distanceMeters;

  /// Total integrated travel time (excludes dropouts/teleports).
  Duration get elapsed => _elapsed;

  /// Travel time with stationary intervals removed — the denominator of the
  /// MOVING average. See [movingAverageMps].
  Duration get movingElapsed => _movingElapsed;

  /// Average ground speed in m/s. Zero until any time has accrued (so there is
  /// never a divide-by-zero, and "no data yet" reads as a clean 0).
  double get averageMps {
    final seconds = _elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0) return 0;
    return _distanceMeters / seconds;
  }

  /// Average ground speed over MOVING time only, in m/s — SPEC-v2 §8's second
  /// average. Same numerator as [averageMps]; the difference is entirely in the
  /// denominator, which skips intervals where the car did not move.
  ///
  /// "Moving" is defined by the distance engine, not by a speed threshold of
  /// our own: a delta that carries no distance is a stop. That reuses the
  /// min-movement floor and accuracy gating already applied in
  /// [GpsDistanceSource], so the two averages can never disagree about what
  /// counts as movement — which a second, independent threshold here would
  /// eventually let them do.
  double get movingAverageMps {
    final seconds = _movingElapsed.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0) return 0;
    return _distanceMeters / seconds;
  }

  /// Fold a distance increment into the running average. This is the path the
  /// live app uses, driven by the distance engine.
  void addDelta(DistanceDelta d) {
    if (!d.meters.isFinite || d.meters < 0) return;
    _elapsed += d.dt;
    // The SOURCE says whether the car was moving; this used to infer it from
    // `d.meters > 0`, which asks a different question — "did this sample bank
    // distance" — and gets a different answer whenever the anchor is held. See
    // [DistanceDelta.moving]: at 5 Hz that inference roughly DOUBLED this
    // average. Corrections carry dt == 0, so they land in neither denominator
    // and inflate neither average.
    if (d.moving) _movingElapsed += d.dt;
    _distanceMeters += d.meters;
  }

  /// Fold a raw GPS fix in directly, deriving the increment with the same
  /// [GpsDistanceSource] the engine uses.
  ///
  /// Kept for driving the integrator straight from a fix sequence (unit tests,
  /// GPX replay) without standing up an engine. The live app goes through
  /// [addDelta].
  void add(GpsSample s) {
    final delta = _gps.add(s);
    if (delta != null) addDelta(delta);
  }

  /// Clear all accumulated distance/time and the anchor (start a fresh leg).
  void reset() {
    _distanceMeters = 0;
    _elapsed = Duration.zero;
    _movingElapsed = Duration.zero;
    _gps.reset();
  }
}
