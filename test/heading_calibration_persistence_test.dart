// C8 — the heading calibration relearned from zero on every launch.
//
// `storage_service.dart` had no key for it, so nothing about the learned offset
// survived the process. Every cold start meant 20 qualifying observations
// before the cluster would say TRUE, and a qualifying observation needs the car
// above 18 km/h on a fix better than 8 m. On a rally that is minutes of driving
// during which the "use true north" switch appears to do nothing at all.
//
// THE THING THIS MUST NOT DO IS ASSERT FROM DISK. A stored offset absorbs two
// different things: declination, which is a property of the LOCATION, and
// hard-iron distortion, which is a property of THIS PHONE IN THIS MOUNT. Drive
// to a different region, or re-seat the phone, and the stored number is wrong.
// Restoring it and immediately labelling the heading TRUE would reintroduce
// exactly the false assertion this whole class exists to prevent, just with an
// extra step.
//
// So `restore()` brings back the OFFSET but not the VERDICT: the observations
// are restored above the count bar and the residual is seeded at the DISBELIEF
// threshold, so a restored offset has to earn its way back. Four agreeing
// observations do it, against twenty from scratch, and a contradicting one
// never does — it relearns instead.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/di/providers.dart';
import 'package:irallymeter/core/storage/storage_service.dart';
import 'package:irallymeter/features/compass/data/heading_calibration_repository.dart';
import 'package:irallymeter/features/compass/domain/heading_calibration.dart';
import 'package:irallymeter/features/compass/presentation/providers/compass_providers.dart';
import 'package:irallymeter/features/gps/domain/gps_repository.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';

void main() {
  group('C8 · a restored calibration, without asserting from disk', () {
    test('01 · restore() brings the offset back', () async {
      final c = HeadingCalibration()..restore(offsetDeg: 5.0, samples: 40);
      expect(c.offsetDeg, closeTo(5.0, 0.001));
    });

    test('02 · a restored calibration does NOT claim TRUE straight away',
        () async {
      // THE ONE THAT MATTERS. The phone may have been re-seated, or the crew
      // may have driven 600 km overnight. Neither is detectable at launch.
      final c = HeadingCalibration()..restore(offsetDeg: 5.0, samples: 40);

      expect(c.isLearned, isFalse,
          reason: 'a number read off disk was presented as a measurement. It '
              'absorbs hard-iron distortion from THIS mount and declination at '
              'THIS location, and neither is known to still hold');
      expect(c.toTrue(100.0), 100.0,
          reason: 'and therefore nothing may be corrected with it yet');
    });

    test('03 · an offset that still AGREES is re-confirmed quickly', () async {
      // The whole point of persisting. From scratch this is 20 observations;
      // restored it should be a handful.
      final c = HeadingCalibration()..restore(offsetDeg: 5.0, samples: 40);

      expect(_observeUntilLearned(c, declination: 5.0, limit: 20), lessThan(8),
          reason: 'restoring saved nothing if re-confirming costs as much as '
              'learning from zero');
      expect(c.isLearned, isTrue);
      expect(c.offsetDeg, closeTo(5.0, 1.0));
    });

    test('04 · an offset that CONTRADICTS the car is not rubber-stamped',
        () async {
      // A single agreeing-looking sample must not be able to confirm a stale
      // offset, which is why the restored residual starts at disbelief rather
      // than at zero.
      final c = HeadingCalibration()..restore(offsetDeg: 5.0, samples: 40);
      for (var i = 0; i < 5; i++) {
        c.observe(gpsCourseDeg: 60, magneticDeg: 0, speedMps: 20, accuracyM: 5);
      }

      expect(c.isLearned, isFalse,
          reason: 'the stored offset was 55 degrees away from what the car is '
              'actually doing and the cluster went on saying TRUE');
    });

    test('05 · but it RELEARNS rather than sulking forever', () async {
      // The other half of 04. A wrong stored offset must not poison the
      // session; it just costs the normal learning time.
      final c = HeadingCalibration()..restore(offsetDeg: 5.0, samples: 40);
      for (var i = 0; i < 60; i++) {
        c.observe(gpsCourseDeg: 60, magneticDeg: 0, speedMps: 20, accuracyM: 5);
      }

      expect(c.isLearned, isTrue);
      expect(c.offsetDeg, closeTo(60, 2.0),
          reason: 'it should converge on what the car is actually telling it');
    });
  });

  group('C8 · it actually survives a relaunch', () {
    late StorageService storage;
    late Directory tempDir;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tempDir = await Directory.systemTemp.createTemp('irallymeter_calpersist');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => tempDir.path,
      );
      storage = await StorageService.init();
    });

    tearDownAll(() async => tempDir.delete(recursive: true));

    test('06 · nothing is written before it is learned', () async {
      final repo = HeadingCalibrationRepository(storage);
      repo.clear();
      final gps = StreamController<GpsSample>();
      final container = _container(storage, gps.stream);

      final sub = container.listen(capHeadingProvider, (_, __) {},
          fireImmediately: true);
      // Ten fixes, half the bar.
      for (var i = 0; i < 10; i++) {
        gps.add(_fix(tMs: 1000 + i * 1000));
        await _pumpAsync();
      }
      expect(repo.load(), isNull,
          reason: 'an unlearned offset is not worth keeping, and writing it '
              'would mean the next launch restores a number nothing agreed on');

      sub.close();
      await gps.close();
      container.dispose();
    });

    test('07 · a learned offset is there on the NEXT launch', () async {
      // THE REGRESSION, end to end: two containers, the second one is the
      // relaunch.
      final repo = HeadingCalibrationRepository(storage);
      repo.clear();

      final gps = StreamController<GpsSample>();
      final first = _container(storage, gps.stream);
      final sub = first.listen(capHeadingProvider, (_, __) {},
          fireImmediately: true);
      for (var i = 0; i < 30; i++) {
        gps.add(_fix(tMs: 1000 + i * 1000));
        await _pumpAsync();
      }
      expect(first.read(headingCalibrationProvider).isLearned, isTrue,
          reason: 'the first session has to learn something to save');
      sub.close();
      await gps.close();
      first.dispose();

      final second = _container(storage, const Stream<GpsSample>.empty());
      final restored = second.read(headingCalibrationProvider);
      expect(restored.offsetDeg, closeTo(6.0, 1.5),
          reason: 'a full session of learning was thrown away at exit, and the '
              'next launch started from zero');
      expect(restored.isLearned, isFalse,
          reason: 'restored, but not yet re-confirmed — see test 02');
      second.dispose();
    });
  });
}

/// Returns how many observations it took to reach [isLearned], or [limit].
int _observeUntilLearned(
  HeadingCalibration c, {
  required double declination,
  required int limit,
}) {
  for (var i = 1; i <= limit; i++) {
    final mag = (i * 9.0) % 360.0;
    c.observe(
      gpsCourseDeg: (mag + declination) % 360.0,
      magneticDeg: mag,
      speedMps: 20,
      accuracyM: 5,
    );
    if (c.isLearned) return i;
  }
  return limit;
}

ProviderContainer _container(StorageService storage, Stream<GpsSample> gps) {
  return ProviderContainer(overrides: [
    storageProvider.overrideWithValue(storage),
    gpsRepositoryProvider.overrideWithValue(_FakeGps(gps)),
    magneticHeadingProvider.overrideWith((ref) => Stream<double>.value(84)),
  ]);
}

Future<void> _pumpAsync() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

GpsSample _fix({required int tMs}) => GpsSample(
      timestamp: DateTime.fromMillisecondsSinceEpoch(tMs),
      latitude: 46.0,
      longitude: 8.0,
      speedMps: 20,
      speedAccuracyMps: 0.5,
      headingDeg: 90,
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
