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
  });

  final DateTime timestamp;
  final double latitude;
  final double longitude;

  /// Raw GPS-reported ground speed in m/s (before app smoothing).
  final double speedMps;

  /// Course over ground in degrees (0..360). NaN when not moving.
  final double headingDeg;

  /// Horizontal accuracy in metres (lower is better).
  final double accuracyM;
  final double altitudeM;

  /// False represents a synthetic "no fix" placeholder.
  final bool hasFix;

  bool get isUsable => hasFix && accuracyM > 0;

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
