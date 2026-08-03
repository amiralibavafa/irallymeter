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
class SpeedFilter {
  double _value = 0;
  bool _seeded = false;

  double add(double rawMps, double accuracyM) {
    // Reject obviously bad fixes — hold previous value rather than spike.
    if (rawMps.isNaN || rawMps < 0) return _value;

    final floored =
        rawMps < AppConstants.speedNoiseFloorMps ? 0.0 : rawMps;

    if (!_seeded) {
      _value = floored;
      _seeded = true;
      return _value;
    }
    const a = AppConstants.speedSmoothing;
    _value = a * floored + (1 - a) * _value;
    // Snap to exact zero once we've decayed close to it, so the display can
    // show a clean 0 when stopped.
    if (_value < 0.15) _value = 0;
    return _value;
  }

  void reset() {
    _value = 0;
    _seeded = false;
  }
}
