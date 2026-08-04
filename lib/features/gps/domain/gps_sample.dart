import '../../../core/constants/app_constants.dart';

/// A single immutable GPS fix, decoupled from the geolocator package so the
/// domain + trip logic stay pure and unit-testable.
class GpsSample {
  const GpsSample({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.speedMps,
    required this.headingDeg,
    required this.accuracyM,
    required this.altitudeM,
    required this.hasFix,
    this.speedAccuracyMps = double.nan,
  });

  final DateTime timestamp;
  final double latitude;
  final double longitude;

  /// Raw GNSS Doppler ground speed in m/s, exactly as the receiver reported it
  /// — including negative and NaN.
  ///
  /// Deliberately NOT sanitised at this boundary. Coercing an unusable reading
  /// to `0` here is indistinguishable from a genuine standstill downstream, and
  /// that is precisely what killed the fallback path SPEC-v2 §7.1 requires:
  /// the derivation from consecutive positions could never fire, because by
  /// the time anything looked, the bad value had already become a plausible
  /// one. Judge validity with [hasValidDopplerSpeed]; never by `== 0`.
  final double speedMps;

  /// Reported uncertainty on [speedMps] in m/s, or NaN when the platform gave
  /// none. SPEC-v2 §7.1 invalidates a speed whose accuracy is worse than 2 m/s.
  final double speedAccuracyMps;

  /// Course over ground in degrees (0..360). NaN when not moving.
  final double headingDeg;

  /// Horizontal accuracy in metres (lower is better).
  final double accuracyM;
  final double altitudeM;

  /// False represents a synthetic "no fix" placeholder.
  final bool hasFix;

  bool get isUsable => hasFix && accuracyM > 0;

  /// Whether the Doppler speed may be used as the primary source (SPEC-v2 §7.1).
  ///
  /// The single home of that rule, so "is this speed trustworthy" is answered
  /// identically by the distance source, the display filter and the estimator.
  /// Invalid when negative, non-finite, or reported with an accuracy worse than
  /// [AppConstants.maxUsableSpeedAccuracyMps].
  ///
  /// A *missing* accuracy (NaN) is treated as acceptable rather than fatal: not
  /// every platform reports one, and rejecting every fix on a device that omits
  /// the field would silently disable the primary speed source entirely — a far
  /// worse failure than trusting an unqualified reading.
  bool get hasValidDopplerSpeed =>
      speedMps.isFinite &&
      speedMps >= 0 &&
      (speedAccuracyMps.isNaN ||
          speedAccuracyMps <= AppConstants.maxUsableSpeedAccuracyMps);

  /// Empty/no-fix sample used as the stream's initial value.
  factory GpsSample.noFix() => GpsSample(
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        latitude: 0,
        longitude: 0,
        speedMps: 0,
        headingDeg: double.nan,
        accuracyM: -1,
        altitudeM: 0,
        hasFix: false,
      );
}

/// Quality buckets that drive the status colour on the dashboard.
enum FixQuality { none, poor, fair, good }
