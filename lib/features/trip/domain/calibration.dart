import '../../../core/constants/app_constants.dart';

/// Rally calibration maths.
///
/// Calibration corrects systematic GPS/route distance error so the trip
/// computer matches the official road-book distance. The classic procedure:
/// drive a known reference distance, read what the meter measured, then the
/// correction factor is `reference / measured`. Subsequent distances are
/// multiplied by this factor.
class Calibration {
  Calibration._();

  /// Factor that maps [measuredMeters] onto [referenceMeters].
  /// Returns 1.0 if inputs are unusable. Result is clamped to the sane band
  /// so a typo can't wildly skew every future trip.
  static double factorFromReference({
    required double measuredMeters,
    required double referenceMeters,
    double current = 1.0,
  }) {
    if (measuredMeters <= 0 || referenceMeters <= 0) return current;
    // measured already had `current` applied, so fold it back out to get the
    // factor relative to RAW GPS distance.
    final rawMeasured = measuredMeters / current;
    final factor = referenceMeters / rawMeasured;
    return factor.clamp(AppConstants.minCalibration, AppConstants.maxCalibration);
  }

  /// Percentage error a factor represents vs uncalibrated (for display).
  static double percentError(double factor) => (factor - 1.0) * 100.0;
}
