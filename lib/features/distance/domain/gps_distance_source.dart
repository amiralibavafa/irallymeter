import 'dart:math' as math;

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
///  • Apply the SPEC-v2 §6.1 noise gates — below 1.5 m/s, or a displacement
///    smaller than the fix's own horizontal accuracy — and report those as ZERO
///    movement rather than dropping them; see below.
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
  /// The DISTANCE anchor. Held in place whenever a displacement is swallowed by
  /// the noise floor, so small real movements accumulate instead of being
  /// discarded — see the gate below.
  GpsSample? _last;

  /// The timestamp of the PREVIOUS SAMPLE, which advances on every accepted fix
  /// whether or not distance was banked.
  ///
  /// These are two different clocks and conflating them double-counts elapsed
  /// time: with the anchor held, consecutive deltas would each report the span
  /// back to the anchor, so a stationary car's average-speed integrator would
  /// accrue six seconds of "elapsed" for four seconds of wall clock.
  DateTime? _lastSampleAt;

  /// Speed of the last accepted pair (m/s). Used only by §6.1 rule 4, to judge
  /// what displacement the NEXT fix should plausibly show. Reset to 0 whenever
  /// a fix is rejected or the anchor moves, so a rejected fix can never become
  /// the baseline for judging the one after it.
  double _lastSpeedMps = 0;

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
      _lastSampleAt = s.timestamp;
      _lastSpeedMps = 0;
      return null; // First usable fix only anchors.
    }

    // Span back to the ANCHOR — this is the interval the displacement covers.
    final dtMs = s.timestamp.difference(prev.timestamp).inMilliseconds;
    // Span back to the PREVIOUS SAMPLE — this is the interval of real time this
    // fix represents, and it is what the delta reports.
    final sampleDtMs =
        s.timestamp.difference(_lastSampleAt ?? prev.timestamp).inMilliseconds;
    // Out-of-order, zero, or post-dropout gap → re-anchor without integrating.
    if (dtMs <= 0 ||
        dtMs > AppConstants.gpsStaleTimeout.inMilliseconds * 3) {
      _last = s;
      _lastSampleAt = s.timestamp;
      _lastSpeedMps = 0;
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
      _lastSampleAt = s.timestamp;
      _lastSpeedMps = 0;
      return null;
    }
    final dtSec = dtMs / 1000.0;
    final impliedSpeed = meters / dtSec;
    if (impliedSpeed > 90.0) {
      _last = s;
      _lastSampleAt = s.timestamp;
      _lastSpeedMps = 0;
      return null;
    }

    // SPEC-v2 §6.1 rule 4: "Reject a fix that implies a speed inconsistent with
    // the previous reading — for example a jump of more than three times the
    // expected displacement."
    //
    // Gated on the vehicle ALREADY MOVING, and that gate is not optional. With
    // a stationary previous fix the expected displacement is ~0, and three
    // times nothing is still nothing, so an ungated rule would reject every
    // pull-away from a standstill and the trip would never start at all.
    //
    // This complements rather than replaces the absolute 90 m/s guard above:
    // that one catches teleports in absolute terms, this one catches jumps that
    // are physically possible for SOME vehicle but not for the one we were just
    // watching.
    if (_lastSpeedMps >= AppConstants.movingThresholdMps &&
        meters > AppConstants.maxJumpFactor * _lastSpeedMps * dtSec) {
      _last = s;
      _lastSpeedMps = 0; // a rejection can never be the baseline for the next
      return null;
    }

    // NOTE: the anchor is deliberately NOT advanced here. See the noise gate
    // below — a fix whose displacement is swallowed by the noise floor must
    // leave the anchor where it is, or that movement is discarded forever.

    // The speed this pair actually happened at (§7.1: Doppler first).
    //
    // A Doppler reading of EXACTLY zero is deliberately not trusted to veto a
    // displacement. Platforms that supply no speed at all report 0.0, not null
    // and not NaN — `gps_providers.dart` documents the Android emulator and
    // "some real GPS chips" doing precisely this. Treating that 0 as an
    // authoritative standstill would gate out every metre on those devices and
    // the app would measure nothing whatsoever, which is a far worse failure
    // than the standstill drift §6.1 exists to stop. When the receiver says
    // zero, the positions get to speak.
    final dopplerUsable = s.hasValidDopplerSpeed && s.speedMps > 0;
    final validSpeed = dopplerUsable ? s.speedMps : impliedSpeed;
    _lastSpeedMps = validSpeed;

    // SPEC-v2 §6.1, rules 2 and 3 — what separates movement from noise.
    //
    //   rule 2: below 1.5 m/s the vehicle is not meaningfully moving, so the
    //           displacement is drift whatever its size.
    //   rule 3: a displacement smaller than the fix's OWN horizontal accuracy
    //           cannot be distinguished from that fix's error. This replaces a
    //           fixed 1.0 m floor, which was the bug: an 8 m fix wanders past
    //           1 m on nearly every sample, so a parked car accumulated
    //           distance indefinitely (2555 m over 10 minutes, measured).
    //
    // Both report an ACCEPTED pair that covered zero ground rather than a
    // rejected one, so elapsed time still accrues and a running average
    // correctly decays toward zero while stopped.
    final noiseFloor =
        math.max(AppConstants.minMovementMeters, s.accuracyM);
    final moving = validSpeed >= AppConstants.movingThresholdMps;
    final moved = (moving && meters >= noiseFloor) ? meters : 0.0;

    // ## The anchor only advances when the distance was actually banked
    //
    // This is the difference between rule 3 filtering noise and rule 3
    // DESTROYING data, and getting it wrong is catastrophic at high fix rates.
    //
    // Re-anchoring on every fix means a displacement below the floor is thrown
    // away and the next fix measures from the new position — so the movement is
    // gone for good. Since the floor is the fix's own accuracy, that rejects
    // every fix where `speed / fixRate < accuracy`:
    //
    //     1 Hz,  5 m accuracy  -> everything below  18 km/h discarded
    //     5 Hz,  5 m accuracy  -> everything below  90 km/h discarded
    //     5 Hz,  8 m accuracy  -> everything below 144 km/h discarded
    //
    // The app REQUESTS 5 Hz (`AppConstants.gpsInterval` = 200 ms). On a chip
    // that honours it, the old behaviour measured NOTHING below 90 km/h. It
    // survived only because most Android chips deliver 1 Hz — a faster receiver
    // made the app worse, which is exactly backwards.
    //
    // Holding the anchor instead lets small real movements ACCUMULATE until
    // they clear the floor, then banks them in one go. The long-run rate is
    // correct at any fix rate, and the anti-drift property is not just kept but
    // improved: a parked car's wander is bounded by its own error box when
    // measured from a fixed point, whereas summing consecutive pairs is a
    // random walk that grows without bound.
    if (moved > 0) _last = s;
    _lastSampleAt = s.timestamp;

    return DistanceDelta(
      timestamp: s.timestamp,
      meters: moved,
      dt: Duration(milliseconds: sampleDtMs),
      // SPEC-v2 §7.1: the GNSS Doppler speed is the primary source, and
      // differentiating positions is the FALLBACK, used only when the receiver
      // reported something unusable — negative, non-finite, or with an accuracy
      // worse than 2 m/s. Doppler is measured independently of position and is
      // materially better than a difference quotient at a 1 Hz update rate.
      // `dopplerUsable`, NOT `hasValidDopplerSpeed`. The two differ on exactly
      // one input and it is the one that matters: a receiver reporting 0.0
      // because it does not support Doppler at all. `hasValidDopplerSpeed`
      // calls that valid, so this used to emit 0.0 while the car was moving.
      //
      // The emitted speed is not cosmetic — DistanceEngine copies it into
      // `_gpsSpeedMps` and SEEDS TUNNEL ESTIMATION with it. So on those
      // devices the app measured open road correctly from `impliedSpeed`
      // above, then entered a tunnel anchored at zero and accrued NOTHING for
      // its whole length. Tunnels are the point of this revision.
      //
      // The distinction is already made three lines up for `validSpeed`; this
      // is the same C6 separation (trustworthy vs preferred) that the display
      // path needed, not carried through to the emit site.
      speedMps: dopplerUsable ? s.speedMps : impliedSpeed,
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
  void reanchor(GpsSample s) {
    _last = s;
    _lastSampleAt = s.timestamp;
    // The blackout invalidates the speed baseline too: judging the first fix
    // after a tunnel against the speed from before it would reject a perfectly
    // good recovery fix.
    _lastSpeedMps = 0;
  }

  /// Forget the anchor (start a fresh leg).
  void reset() {
    _last = null;
    _lastSampleAt = null;
    _lastSpeedMps = 0;
  }
}
