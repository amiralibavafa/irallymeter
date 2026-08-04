import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/features/gps/domain/gps_health_stats.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';

/// §19 row 6 was recorded as "cannot be verified — device property". That was
/// only true because nothing measured it. This is the measurement.
GpsSample fix({double acc = 5, bool hasFix = true}) => GpsSample(
      timestamp: DateTime.utc(2026),
      latitude: 35.7,
      longitude: 51.4,
      speedMps: 20,
      speedAccuracyMps: 0.5,
      headingDeg: 0,
      accuracyM: acc,
      altitudeM: 1200,
      hasFix: hasFix,
    );

void main() {
  final t0 = DateTime.utc(2026);

  test('01 · a steady 1 Hz stream reports 1 Hz and meets §19 row 6', () {
    final s = GpsHealthStats();
    for (var i = 0; i < 60; i++) {
      s.add(fix(), t0.add(Duration(seconds: i)));
    }
    expect(s.sustainedHz, closeTo(1.0, 0.01));
    expect(s.meetsRow6, isTrue);
  });

  test('02 · a burst followed by silence does NOT flatter the rate', () {
    // The failure this guards: 60 fixes in 5 s then nothing for a minute is
    // not "12 Hz sustained", it is a receiver that quit.
    final s = GpsHealthStats();
    for (var i = 0; i < 60; i++) {
      s.add(fix(), t0.add(Duration(milliseconds: i * 80)));
    }
    s.add(fix(), t0.add(const Duration(seconds: 65)));
    expect(s.sustainedHz, lessThan(1.0));
    expect(s.meetsRow6, isFalse);
  });

  test('03 · a 0.5 Hz stream fails row 6, which is the point', () {
    final s = GpsHealthStats();
    for (var i = 0; i < 30; i++) {
      s.add(fix(), t0.add(Duration(seconds: i * 2)));
    }
    expect(s.sustainedHz, closeTo(0.5, 0.02));
    expect(s.meetsRow6, isFalse);
  });

  test('04 · a tunnel shows as the longest gap, not as a stall', () {
    final s = GpsHealthStats();
    for (var i = 0; i < 20; i++) {
      s.add(fix(), t0.add(Duration(seconds: i)));
    }
    s.add(fix(), t0.add(const Duration(seconds: 420)));
    expect(s.longestGap.inSeconds, 401);
    expect(s.gapsOver3s, 1);
    expect(s.stalls, 0,
        reason: 'a tunnel must never tear the subscription down — that is the '
            '[3.15] guarantee, and this is how the road test checks it');
  });

  test('05 · the watchdog heartbeat is counted separately from real fixes', () {
    final s = GpsHealthStats();
    s.add(fix(), t0);
    for (var i = 1; i < 5; i++) {
      s.add(GpsSample.noFix(), t0.add(Duration(seconds: i * 20)));
    }
    expect(s.fixes, 1);
    expect(s.noFixSamples, 4);
  });

  test('06 · accuracy is tracked best/mean/worst for the road-test report', () {
    final s = GpsHealthStats();
    for (final a in [4.0, 8.0, 30.0]) {
      s.add(fix(acc: a), t0);
    }
    expect(s.bestAccuracyM, 4.0);
    expect(s.worstAccuracyM, 30.0);
    expect(s.meanAccuracyM, closeTo(14.0, 0.01));
  });

  test('07 · an empty stream reports zero rather than NaN', () {
    final s = GpsHealthStats();
    expect(s.sustainedHz, 0);
    expect(s.meanAccuracyM, 0);
    expect(s.meetsRow6, isFalse);
  });
}
