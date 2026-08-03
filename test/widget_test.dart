import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/utils/formatters.dart';
import 'package:irallymeter/core/utils/geo_math.dart';
import 'package:irallymeter/features/gps/domain/gps_state.dart';
import 'package:irallymeter/features/trip/domain/calibration.dart';

void main() {
  group('Formatters', () {
    test('speed converts m/s to km/h and mph (rounded)', () {
      expect(Formatters.speed(10, SpeedUnit.kmh), 36); // 10 m/s = 36 km/h
      expect(Formatters.speed(10, SpeedUnit.mph), 22);
      expect(Formatters.speed(-1, SpeedUnit.kmh), 0);
    });

    test('heading is zero-padded 3 digits', () {
      expect(Formatters.heading(5), '005');
      expect(Formatters.heading(360), '000');
      expect(Formatters.heading(127.6), '128');
    });

    test('trip formats with 2 decimals', () {
      expect(Formatters.trip(1234, metric: true), '1.23');
    });

    test('stopwatch shows tenths', () {
      expect(Formatters.stopwatch(const Duration(seconds: 65, milliseconds: 400)), '01:05.4');
    });
  });

  group('GeoMath', () {
    test('distance between two close points is sane', () {
      // ~111 m for 0.001 deg latitude.
      final d = GeoMath.distanceMeters(46.0, 8.0, 46.001, 8.0);
      expect(d, closeTo(111.0, 1.0));
    });

    test('angle smoothing wraps across 0/360', () {
      final r = GeoMath.smoothAngle(350, 10, 0.5);
      expect(r, closeTo(0.0, 0.001)); // halfway between 350 and 10 is 0/360
    });
  });

  group('SpeedFilter', () {
    test('floors sub-threshold noise to zero', () {
      final f = SpeedFilter();
      expect(f.add(0.2, 5), 0); // below noise floor
    });

    test('EMA smooths toward target', () {
      final f = SpeedFilter()..add(0, 5);
      final v = f.add(10, 5);
      expect(v, greaterThan(0));
      expect(v, lessThan(10));
    });
  });

  group('Calibration', () {
    test('reference factor maps measured onto reference', () {
      // Meter read 9.9 km over a true 10.0 km, uncalibrated.
      final f = Calibration.factorFromReference(
        measuredMeters: 9900,
        referenceMeters: 10000,
      );
      expect(f, closeTo(1.0101, 0.001));
    });

    test('factor is clamped to sane band', () {
      final f = Calibration.factorFromReference(measuredMeters: 100, referenceMeters: 10000);
      expect(f, lessThanOrEqualTo(1.20));
    });
  });
}
