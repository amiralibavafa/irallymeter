import 'dart:math' as math;

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/geo_math.dart';

/// Learns the offset between the phone's magnetic heading and true north, from
/// the app's own GPS.
///
/// ## Why this exists rather than a magnetic model
///
/// The cluster has a "Use true north" switch, and until now it changed only a
/// LABEL: `headingSourceProvider` returned the string `'TRUE'` while the value
/// on screen was still a raw magnetic reading. Declination in Iran is roughly
/// +4.5° to +6° east, so the compass was several degrees wrong and saying
/// otherwise. A display that asserts something false is worse than one that
/// admits it does not know.
///
/// The obvious fix is a world magnetic model, but there is a better source
/// already in the app: **GPS course over ground is true-north referenced.**
/// Whenever the vehicle is moving with a good fix, the difference between GPS
/// course and the magnetometer's heading IS the correction, and it costs no
/// model, no coefficient table and no network.
///
/// It also corrects something a magnetic model cannot: **hard-iron distortion
/// from this particular car.** A phone in a mount surrounded by steel, speaker
/// magnets and a charging cable reads a bias that is a property of the
/// installation, not of the location. Learning the offset in situ absorbs both
/// the declination and that bias in one number.
///
/// ## What it deliberately does not do
///
/// It learns only while the vehicle is clearly moving on a good fix, because a
/// GPS course derived from a crawling or stationary vehicle is noise. Until it
/// has enough agreeing samples it reports [isLearned] false, and the caller
/// must keep saying MAG rather than pretending.
///
/// Pure Dart, no clock of its own — every input is passed in.
class HeadingCalibration {
  double _offsetDeg = 0;
  int _samples = 0;
  double _residualDeg = 0;
  bool _agreed = false;

  /// Degrees to ADD to a magnetic heading to get true north. Meaningless until
  /// [isLearned].
  double get offsetDeg => _offsetDeg;

  int get samples => _samples;

  /// Rolling mean absolute distance between a fresh observation and the running
  /// offset. Exposed rather than kept private because a gate nobody can read is
  /// a gate nobody can debug on a road test.
  double get residualDeg => _residualDeg;

  /// Whether enough consistent observations have accumulated to trust
  /// [offsetDeg] — and therefore whether the cluster may say TRUE.
  ///
  /// The count used to be the whole test, which made the word "consistent"
  /// above a claim the code never checked: twenty mutually contradictory
  /// observations cleared the bar exactly as readily as twenty agreeing ones.
  /// Hard-iron distortion from a magnetic phone mount is HEADING-DEPENDENT, so
  /// that is an ordinary installation rather than a contrived one — the EMA
  /// settles on an average that is wrong at every heading and the cluster says
  /// TRUE about it.
  ///
  /// [_agreed] is latched with a band rather than compared directly, for the
  /// same reason the heading source is: a residual sitting on a single
  /// threshold would blink TRUE/MAG on alternate fixes, and a cluster whose
  /// label blinks reads as a broken cluster. It is also allowed to go BACK to
  /// false — a phone re-seated in its mount invalidates what was learned, and
  /// continuing to assert TRUE afterwards is the failure this class exists to
  /// prevent.
  bool get isLearned =>
      _samples >= AppConstants.headingCalibrationSamples && _agreed;

  /// Fold in one observation.
  ///
  /// [gpsCourseDeg] must be a course over ground from a moving vehicle;
  /// [magneticDeg] the magnetometer heading at the same moment. Returns true if
  /// the pair was used.
  bool observe({
    required double gpsCourseDeg,
    required double magneticDeg,
    required double speedMps,
    required double accuracyM,
  }) {
    if (!gpsCourseDeg.isFinite || !magneticDeg.isFinite) return false;

    // A course from a vehicle that is barely moving is direction-of-noise, not
    // direction-of-travel. This threshold is deliberately far above §6.1's
    // moving gate: heading needs more evidence than distance does.
    if (!(speedMps >= AppConstants.headingCalibrationMinSpeedMps)) return false;
    if (!(accuracyM > 0 && accuracyM <= AppConstants.goodAccuracyMeters)) {
      return false;
    }

    final delta = GeoMath.angleDelta(magneticDeg, gpsCourseDeg);
    if (!delta.isFinite) return false;

    if (_samples == 0) {
      _offsetDeg = delta;
    } else {
      // Circular EMA: average the DIFFERENCE from the running offset, never the
      // raw angles, so a pair straddling 0°/360° cannot drag the mean halfway
      // around the dial.
      final err = GeoMath.angleDelta(_offsetDeg, delta);
      _offsetDeg += AppConstants.headingCalibrationSmoothing * err;
      // Track how much the observations DISAGREE, at the same rate as the
      // offset itself so the two are always describing the same window.
      _residualDeg += AppConstants.headingCalibrationSmoothing *
          (err.abs() - _residualDeg);
    }
    _offsetDeg = _wrapSigned(_offsetDeg);
    _samples++;

    // Evaluated only once the count bar is met, because before that the
    // residual EMA has barely converged and would read agreement into two or
    // three samples that happened to line up.
    if (_samples >= AppConstants.headingCalibrationSamples) {
      if (!_agreed && _residualDeg <= AppConstants.headingCalibrationAgreeDeg) {
        _agreed = true;
      } else if (_agreed &&
          _residualDeg > AppConstants.headingCalibrationDisagreeDeg) {
        _agreed = false;
      }
    }
    return true;
  }

  /// Apply the learned correction. Returns the input unchanged when nothing has
  /// been learned — never a guess dressed up as a measurement.
  double toTrue(double magneticDeg) {
    if (!isLearned || !magneticDeg.isFinite) return magneticDeg;
    return (magneticDeg + _offsetDeg + 360.0) % 360.0;
  }

  /// Bring back an offset learned in a PREVIOUS session.
  ///
  /// Restores the offset but deliberately NOT the verdict. A stored offset
  /// absorbs two things at once: declination, a property of the LOCATION, and
  /// hard-iron distortion, a property of THIS phone in THIS mount. Drive to a
  /// different region overnight, or re-seat the phone, and the number is wrong
  /// — and neither is detectable at launch. Restoring it and going straight to
  /// TRUE would be the same false assertion this class exists to prevent, with
  /// an extra step.
  ///
  /// So [_agreed] starts false and the residual starts at DISBELIEF rather than
  /// at zero. Seeding it at zero would let a single agreeing-looking sample
  /// rubber-stamp a stale offset; starting at the release threshold means the
  /// residual has to be pulled down by observations that actually agree. That
  /// costs about four of them, against twenty from scratch, which is the whole
  /// point of persisting. An offset that contradicts the car is never confirmed
  /// and simply relearns.
  void restore({required double offsetDeg, required int samples}) {
    if (!offsetDeg.isFinite || samples <= 0) return;
    _offsetDeg = _wrapSigned(offsetDeg);
    // At or above the bar, so agreement is judged on the very first new
    // observation rather than after another twenty.
    _samples = samples < AppConstants.headingCalibrationSamples
        ? AppConstants.headingCalibrationSamples
        : samples;
    _residualDeg = AppConstants.headingCalibrationDisagreeDeg;
    _agreed = false;
  }

  void reset() {
    _offsetDeg = 0;
    _samples = 0;
    _residualDeg = 0;
    _agreed = false;
  }

  /// Wrap to (-180, 180]. Declination is a small angle; a value near ±180 means
  /// the phone is reading backwards, which we still represent honestly.
  static double _wrapSigned(double deg) {
    var d = (deg + 180.0) % 360.0;
    if (d < 0) d += 360.0;
    return d - 180.0;
  }
}

/// Time-based low-pass for the gravity vector used in tilt compensation.
///
/// The third and last cause behind "the compass isn't accurate". `CompassService`
/// derived "which way is down" from `accelerometerEventStream()`, which reports
/// gravity PLUS whatever the vehicle is doing, with a fixed per-sample weight of
/// 0.2. That is fast enough to track braking and cornering, so the tilt
/// correction was wrong exactly when the car was manoeuvring — which is when
/// anyone looks at a compass.
///
/// Two changes: the weight is derived from elapsed time (so the behaviour does
/// not depend on the device's sensor rate — the same mistake as the speed
/// display and the needle), and the time constant is long. Gravity is constant;
/// the only thing that legitimately moves it is the phone being re-seated in its
/// mount, which is rare and slow. Vehicle acceleration is transient — a hard
/// brake is a second or two — so a multi-second constant rejects it while still
/// following a genuine re-orientation within a few seconds.
class GravityLowPass {
  GravityLowPass(this.tau);

  final Duration tau;

  double x = 0, y = 0, z = 9.81;
  DateTime? _lastAt;
  bool _seeded = false;

  bool get isSeeded => _seeded;

  void add(double ax, double ay, double az, DateTime at) {
    if (!ax.isFinite || !ay.isFinite || !az.isFinite) return;

    final last = _lastAt;
    _lastAt = at;

    if (!_seeded || last == null) {
      x = ax;
      y = ay;
      z = az;
      _seeded = true;
      return;
    }

    final dt = at.difference(last);
    if (dt <= Duration.zero) return; // out-of-order: hold

    final a = (1 - math.exp(-dt.inMicroseconds / tau.inMicroseconds))
        .clamp(0.0, 1.0);
    x += a * (ax - x);
    y += a * (ay - y);
    z += a * (az - z);
  }

  void reset() {
    x = 0;
    y = 0;
    z = 9.81;
    _lastAt = null;
    _seeded = false;
  }
}
