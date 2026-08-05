// C6 (and C11 with it) — the speedometer and the odometer disagreed about
// which readings were trustworthy.
//
// `GpsSample.hasValidDopplerSpeed` carries a doc comment calling itself "the
// single home of that rule, so 'is this speed trustworthy' is answered
// identically by the distance source, the display filter and the estimator."
//
// The display filter never asked it. `gps_providers.dart` decided with:
//
//     var rawSpeed = s.speedMps;
//     if (rawSpeed <= 0 && prev != null) { ...differentiate positions... }
//
// while `gps_distance_source.dart:157` decided with:
//
//     final dopplerUsable = s.hasValidDopplerSpeed && s.speedMps > 0;
//
// Two consequences, both real:
//
//  * A Doppler speed reported with an accuracy of 9 m/s is rejected by §7.1 and
//    by the distance engine, and was rendered on the speedometer anyway. For a
//    measurement instrument, the digit and the distance being computed from
//    different inputs is a correctness bug, not a cosmetic one.
//
//  * C11: `NaN <= 0` is FALSE in Dart, so a non-finite Doppler reading skipped
//    the fallback entirely and went into `SpeedFilter.add`, which rejects NaN by
//    HOLDING its previous value. A receiver that starts reporting NaN therefore
//    freezes the speedometer at its last good number for as long as it keeps
//    doing it. Latent on Android, which sends 0.0, but it is the same line.
//
// One change closes both, because it was one line making both decisions.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/features/gps/domain/gps_repository.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';
import 'package:irallymeter/features/gps/domain/gps_state.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';

// 100 m of latitude, and 5 s between fixes, so the positions imply 20 m/s.
// 100 / 6371000 rad, in degrees.
const _lat0 = 46.0;
const _lat1 = 46.0 + 0.00089928;

void main() {
  group('C6 · the display trusts exactly what the distance engine trusts', () {
    test('01 · a Doppler speed with a USELESS accuracy is not displayed',
        () async {
      // THE REGRESSION. §7.1 invalidates a speed reported with an accuracy
      // worse than 2 m/s, and gps_distance_source honours that. The
      // speedometer rendered it regardless.
      final speeds = await _run([
        _fix(tMs: 0, lat: _lat0, speed: 0, speedAcc: 0.5),
        _fix(tMs: 5000, lat: _lat1, speed: 50, speedAcc: 9.0),
      ]);

      expect(speeds.last, lessThan(40),
          reason: 'the cluster showed 50 m/s (180 km/h) from a reading whose '
              'own reported uncertainty was 9 m/s, while the distance engine '
              'threw the same reading away and used the positions. The digit '
              'and the odometer were being computed from different inputs');
      expect(speeds.last, closeTo(20, 3),
          reason: 'having rejected it, the display should differentiate the '
              'positions — the same fallback §7.1 gives the distance path');
    });

    test('02 · display and distance engine agree on the same fix', () async {
      // The general statement. hasValidDopplerSpeed exists to be the one home
      // of this rule, so both consumers should reach the same verdict without
      // either restating it.
      final s = _fix(tMs: 5000, lat: _lat1, speed: 50, speedAcc: 9.0);
      expect(s.hasValidDopplerSpeed, isFalse,
          reason: 'the shared rule already rejects this reading');

      final speeds = await _run([
        _fix(tMs: 0, lat: _lat0, speed: 0, speedAcc: 0.5),
        s,
      ]);
      expect(speeds.last, closeTo(20, 3),
          reason: 'the display reached the opposite verdict to the rule its '
              'own doc comment claims it consults');
    });

    test('03 · C11 — a NaN Doppler falls back instead of FREEZING', () async {
      // `NaN <= 0` is false, so the old guard skipped the fallback and handed
      // NaN to SpeedFilter, which holds its previous value on NaN. The needle
      // stops moving and nothing says so.
      final speeds = await _run([
        _fix(tMs: 0, lat: _lat0, speed: 30, speedAcc: 0.5),
        _fix(tMs: 5000, lat: _lat1, speed: double.nan, speedAcc: 0.5),
      ]);

      expect(speeds.last, closeTo(20, 3),
          reason: 'the speedometer froze at the last good reading of 30 m/s '
              'and kept showing it while the car slowed to 20. A frozen '
              'instrument that looks live is the worst kind');
    });

    test('04 · a reported ZERO while moving still falls back', () async {
      // The emulator and some real chips never report a speed at all. This is
      // the case the original `rawSpeed <= 0` guard existed for, and the fix
      // must not lose it: hasValidDopplerSpeed alone would call 0 valid.
      final speeds = await _run([
        _fix(tMs: 0, lat: _lat0, speed: 0, speedAcc: 0.5),
        _fix(tMs: 5000, lat: _lat1, speed: 0, speedAcc: 0.5),
      ]);

      expect(speeds.last, closeTo(20, 3),
          reason: 'a receiver that reports 0 m/s while the positions clearly '
              'move must not gate the readout to zero — the app would measure '
              'nothing at all on those devices');
    });

    test('05 · a GOOD Doppler reading is still preferred', () async {
      // The fallback must stay a fallback. Doppler is measured independently of
      // position and is materially better than a difference quotient at 1 Hz.
      final speeds = await _run([
        _fix(tMs: 0, lat: _lat0, speed: 25, speedAcc: 0.5),
        _fix(tMs: 5000, lat: _lat1, speed: 25, speedAcc: 0.5),
      ]);

      expect(speeds.last, closeTo(25, 1),
          reason: 'the positions imply 20 but the receiver measured 25, and '
              'the receiver wins when its reading is trustworthy');
    });
  });
}

Future<List<double>> _run(List<GpsSample> fixes) async {
  final controller = StreamController<GpsSample>();
  final container = ProviderContainer(overrides: [
    gpsRepositoryProvider.overrideWithValue(_FakeGps(controller.stream)),
  ]);
  addTearDown(container.dispose);

  final out = <double>[];
  final sub = container.listen<AsyncValue<GpsState>>(
    gpsStateProvider,
    (_, next) {
      final v = next.valueOrNull;
      if (v != null) out.add(v.smoothedSpeedMps);
    },
    fireImmediately: true,
  );
  addTearDown(sub.close);

  for (final f in fixes) {
    controller.add(f);
    await _pump();
  }
  await controller.close();
  await _pump();
  return out;
}

Future<void> _pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

GpsSample _fix({
  required int tMs,
  required double lat,
  required double speed,
  required double speedAcc,
}) {
  return GpsSample(
    timestamp: DateTime.fromMillisecondsSinceEpoch(tMs),
    latitude: lat,
    longitude: 8.0,
    speedMps: speed,
    speedAccuracyMps: speedAcc,
    headingDeg: 0,
    accuracyM: 4,
    altitudeM: 0,
    hasFix: true,
  );
}

class _FakeGps implements GpsRepository {
  _FakeGps(this._stream);
  final Stream<GpsSample> _stream;

  @override
  Stream<GpsSample> positionStream() => _stream;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<GpsSample?> lastKnown() async => null;
}
