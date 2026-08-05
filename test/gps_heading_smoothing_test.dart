// C10 — the GPS heading branch lagged by SAMPLES, not by time.
//
// `[3.7]` fixed exactly this shape of bug on the speed display, and `[3.11]`
// fixed it again on the magnetic compass, where a fixed per-sample weight made
// the needle's lag a property of whatever rate the handset's magnetometer
// happened to run at. `app_constants.dart` even said so: `headingSmoothing` was
// documented as "still used for the GPS-course branch".
//
// It is the same bug there, and it matters more, because since C1 the GPS
// branch is the one displayed nearly all the time. `Geolocator` is asked for
// 5 Hz, and delivers that only when the sky is open; under trees, in a canyon
// or on a weak receiver it drops towards 1 Hz. With a per-sample weight the
// needle settles in about 4.5 SAMPLES, so it settles in a second on a good fix
// and in four and a half seconds on a poor one, on the same phone, on the same
// road. A driver reads that as the compass "getting laggy" exactly when the
// conditions are already bad.
//
// The test drives the identical manoeuvre at 5 Hz and at 1 Hz and compares the
// two after the same ELAPSED TIME. That is the only comparison that can tell
// the two designs apart.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/constants/app_constants.dart';
import 'package:irallymeter/features/gps/domain/gps_repository.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';
import 'package:irallymeter/features/gps/domain/gps_state.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';

void main() {
  group('C10 · the heading lags by TIME, not by fix count', () {
    test('01 · 5 Hz and 1 Hz agree after the same elapsed second', () async {
      // THE REGRESSION. Same turn, same second, two fix rates.
      final fast = await _turnThen(intervalMs: 200, forMs: 1000);
      final slow = await _turnThen(intervalMs: 1000, forMs: 1000);

      expect((fast - slow).abs(), lessThan(3.0),
          reason: 'the same manoeuvre over the same second produced $fast at '
              '5 Hz and $slow at 1 Hz. The needle settled in about 4.5 SAMPLES, '
              'so it was fast on an open sky and sluggish under trees — on the '
              'same phone, on the same road');
    });

    test('02 · and both match what the time constant predicts', () async {
      // Pinning the behaviour, not just the agreement: two equally wrong
      // numbers would also agree.
      //
      // A 400 ms time constant is 1 - e^-2.5 of the way through a step after
      // one second, so a 0 -> 90 turn should read about 82.6.
      final expected = 90 * (1 - math.exp(-1000 / 400));

      expect(await _turnThen(intervalMs: 200, forMs: 1000),
          closeTo(expected, 3.0));
      expect(await _turnThen(intervalMs: 1000, forMs: 1000),
          closeTo(expected, 3.0));
      expect(AppConstants.headingSmoothingTau.inMilliseconds, 400,
          reason: 'the number above is derived from this one');
    });

    test('03 · a stop still releases, and re-acquiring adopts the new course',
        () async {
      // The smoother carries state, so it has to be reset when the source is
      // released — otherwise re-acquisition would smooth up from a pre-stop
      // bearing, which is the fault C1's test 04 pins.
      final r = await _run([
        _fix(speed: 20, head: 90, tMs: 1000),
        _fix(speed: 20, head: 90, tMs: 2000),
        _fix(speed: 0, head: 90, tMs: 3000), // release
        _fix(speed: 20, head: 270, tMs: 4000), // moving again, opposite way
      ]);

      expect(r.last.headingDeg, closeTo(270, 1.0),
          reason: 're-acquisition smoothed up from the stale pre-stop bearing '
              'instead of adopting the new course');
    });
  });
}

/// Drive north, then turn to 090 and hold it for [forMs] at [intervalMs].
/// Returns the smoothed heading at the end.
Future<double> _turnThen({
  required int intervalMs,
  required int forMs,
}) async {
  final fixes = <GpsSample>[
    _fix(speed: 20, head: 0, tMs: 0), // seed the smoother at 000
  ];
  for (var t = intervalMs; t <= forMs; t += intervalMs) {
    fixes.add(_fix(speed: 20, head: 90, tMs: t));
  }
  final r = await _run(fixes);
  return r.last.headingDeg;
}

Future<List<GpsState>> _run(List<GpsSample> fixes) async {
  final controller = StreamController<GpsSample>();
  final container = ProviderContainer(overrides: [
    gpsRepositoryProvider.overrideWithValue(_FakeGps(controller.stream)),
  ]);
  addTearDown(container.dispose);

  final out = <GpsState>[];
  final sub = container.listen<AsyncValue<GpsState>>(
    gpsStateProvider,
    (_, next) {
      final v = next.valueOrNull;
      if (v != null) out.add(v);
    },
    fireImmediately: true,
  );
  addTearDown(sub.close);

  for (final f in fixes) {
    controller.add(f);
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  await controller.close();
  return out;
}

GpsSample _fix({
  required double speed,
  required double head,
  required int tMs,
}) =>
    GpsSample(
      timestamp: DateTime.fromMillisecondsSinceEpoch(tMs),
      latitude: 46.0,
      longitude: 8.0,
      speedMps: speed,
      speedAccuracyMps: 0.5,
      headingDeg: head,
      accuracyM: 4,
      altitudeM: 0,
      hasFix: true,
    );

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
