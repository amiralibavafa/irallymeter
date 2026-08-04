import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/core/constants/app_constants.dart';
import 'package:irallymeter/features/distance/domain/gps_distance_source.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';

/// SPEC-v2 §7.1 — where the speed number comes from.
///
/// "Speed is read directly from the GNSS receiver. It is not calculated by
/// dividing distance by time." The Doppler value is primary; differentiating
/// consecutive positions is the FALLBACK, reached only when the receiver
/// reported something unusable.
///
/// The regression these lock down: the service used to coerce an unusable
/// Doppler reading to `0` at the platform boundary. Downstream, `0` is
/// indistinguishable from a genuine standstill, so the fallback in
/// [GpsDistanceSource] could never fire — it was unreachable code that looked
/// like a safety net.
GpsSample fix({
  required int atMs,
  required double lat,
  double speed = 10.0,
  double speedAcc = double.nan,
  double accuracy = 5.0,
}) =>
    GpsSample(
      timestamp: DateTime.utc(2026).add(Duration(milliseconds: atMs)),
      latitude: lat,
      longitude: 51.389,
      speedMps: speed,
      speedAccuracyMps: speedAcc,
      headingDeg: 0,
      accuracyM: accuracy,
      altitudeM: 1200,
      hasFix: true,
    );

/// Degrees of latitude per metre north, matching GeoMath's sphere.
const double degPerM = 8.993216059187306e-6;

void main() {
  group('§7.1 · Doppler validity', () {
    test('01 · an ordinary reading with no reported accuracy is valid', () {
      // Not every platform reports speedAccuracy. Rejecting those would
      // silently disable the primary source on whole classes of device.
      expect(fix(atMs: 0, lat: 0, speed: 25.0).hasValidDopplerSpeed, isTrue);
    });

    test('02 · accuracy at exactly 2 m/s is still valid (boundary)', () {
      expect(
        fix(atMs: 0, lat: 0, speed: 25.0, speedAcc: 2.0).hasValidDopplerSpeed,
        isTrue,
      );
      expect(AppConstants.maxUsableSpeedAccuracyMps, 2.0);
    });

    test('03 · accuracy worse than 2 m/s is invalid', () {
      expect(
        fix(atMs: 0, lat: 0, speed: 25.0, speedAcc: 2.5).hasValidDopplerSpeed,
        isFalse,
      );
    });

    test('04 · a negative speed is invalid', () {
      expect(fix(atMs: 0, lat: 0, speed: -1.0).hasValidDopplerSpeed, isFalse);
    });

    test('05 · a non-finite speed is invalid', () {
      expect(
        fix(atMs: 0, lat: 0, speed: double.nan).hasValidDopplerSpeed,
        isFalse,
      );
    });
  });

  group('§7.1 · source selection in GpsDistanceSource', () {
    test('06 · a valid Doppler reading is used verbatim, not re-derived', () {
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, lat: 35.0, speed: 25.0, speedAcc: 0.5));
      // Move 10 m in 1 s — differentiation would say 10 m/s. Doppler says 25.
      final d = src.add(fix(
        atMs: 1000,
        lat: 35.0 + 10 * degPerM,
        speed: 25.0,
        speedAcc: 0.5,
      ))!;
      expect(d.speedMps, closeTo(25.0, 1e-6),
          reason: 'Doppler is measured independently of position and is the '
              'primary source; it must not be overridden by the difference '
              'quotient');
    });

    test('07 · a Doppler reading with poor accuracy falls back to derivation',
        () {
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, lat: 35.0, speed: 25.0, speedAcc: 9.0));
      final d = src.add(fix(
        atMs: 1000,
        lat: 35.0 + 10 * degPerM,
        speed: 25.0,
        speedAcc: 9.0,
      ))!;
      expect(d.speedMps, closeTo(10.0, 1e-3),
          reason: '25 m/s reported at ±9 m/s is not a measurement; 10 m in 1 s '
              'is');
    });

    test('08 · a negative Doppler reading falls back to derivation', () {
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, lat: 35.0, speed: -1.0));
      final d = src.add(fix(atMs: 1000, lat: 35.0 + 10 * degPerM, speed: -1.0))!;
      expect(d.speedMps, closeTo(10.0, 1e-3));
    });

    test('09 · a NaN Doppler reading falls back to derivation', () {
      // THE REGRESSION TEST. Before D1 this could not even be constructed:
      // the platform boundary turned NaN into 0, and 0 read as a valid
      // standstill, so the fallback below was unreachable.
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, lat: 35.0, speed: double.nan));
      final d = src.add(
          fix(atMs: 1000, lat: 35.0 + 10 * degPerM, speed: double.nan))!;
      expect(d.speedMps, closeTo(10.0, 1e-3),
          reason: 'a receiver that reports no speed must not read as a '
              'stationary vehicle');
    });

    test('10 · a Doppler-less drive still anchors a real tunnel entry speed',
        () {
      // Why 09 matters beyond cosmetics: DistanceDelta.speedMps is what the
      // engine seeds the sensor estimate with on tunnel entry. With the old
      // coercion this was 0 on a Doppler-less device, so the car would coast
      // at a standstill through the whole blackout and measure nothing.
      final src = GpsDistanceSource();
      src.add(fix(atMs: 0, lat: 35.0, speed: double.nan));
      final d = src.add(
          fix(atMs: 1000, lat: 35.0 + 25 * degPerM, speed: double.nan))!;
      expect(d.speedMps, greaterThan(20.0));
    });
  });
}
