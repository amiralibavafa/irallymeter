// C4 — the true-north calibration silently never ran in the common case.
//
// `headingCalibrationProvider` learns the magnetic-to-true offset by folding in
// pairs of (GPS course, magnetometer heading) while the car is clearly moving.
// A Riverpod `Provider` is created LAZILY on first read, and its `ref.listen`
// only starts when it is created — so the whole thing hinges on somebody
// reading it early.
//
// Nobody did. Both readers sat behind early returns:
//
//   capHeadingProvider     :61  if (gpsHeading.isFinite) return gpsHeading;
//                          :67  if (!wantsTrue) return mag;
//   headingSourceProvider  :78  if (heading.isFinite) return 'GPS';
//                          :81  if (!wantsTrue) return 'MAG';
//
// The first guard is the one that bites: while the car is MOVING the GPS course
// is finite, so the display never falls through to the magnetic branch, so the
// calibration provider is never created — and moving is the only time it can
// learn anything. The second guard means a driver who leaves "use true north"
// off (the default) never creates it at all, so toggling the switch on after an
// hour of driving starts learning from zero.
//
// The failure is silent and it reads as its own opposite: the cluster says
// `MAG`, which looks like "still learning" and actually means "not learning".
//
// The fix is to read the calibration BEFORE the guards, so the display path
// cannot skip it. `HeadingDisplay` watches `capHeadingProvider` from app start,
// and neither provider is autoDispose, so one read keeps the listener alive for
// the session.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/di/providers.dart';
import 'package:irallymeter/core/storage/storage_service.dart';
import 'package:irallymeter/features/compass/presentation/providers/compass_providers.dart';
import 'package:irallymeter/features/gps/domain/gps_repository.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';
import 'package:irallymeter/features/settings/presentation/providers/settings_providers.dart';

void main() {
  late StorageService storage;
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('irallymeter_headingcal');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    storage = await StorageService.init();
  });

  tearDownAll(() async => tempDir.delete(recursive: true));

  group('C4 · the calibration learns while the car is moving', () {
    test('01 · a moving drive TEACHES it, with true north off', () async {
      // THE REGRESSION. True north off is the default, so this is what almost
      // every drive looked like: the display returned the raw magnetic heading
      // without ever touching the calibration, and an entire session of perfect
      // learning conditions was thrown away.
      final h = await _drive(storage, trueNorth: false);

      expect(h.samples, greaterThan(0),
          reason: 'a full drive at 20 m/s on a 4 m fix taught the calibration '
              'NOTHING. Both readers sit behind early returns, so the provider '
              'was never created and its listener never ran');
    });

    test('02 · the FIRST moving segment is not wasted', () async {
      // Even with the switch already on, the guard at capHeadingProvider:61
      // means a moving car never reaches the magnetic branch. So the provider
      // only came into existence at the first STOP, and learning only happens
      // while MOVING — the first leg was always lost.
      final h = await _drive(storage, trueNorth: true);

      expect(h.isLearned, isTrue,
          reason: 'the drive was long enough to learn from, but the provider '
              'did not exist yet while the car was moving');
      expect(h.offsetDeg, closeTo(6, 1.5),
          reason: 'GPS course 90, magnetometer 84, so the offset to add is +6');
    });

    test('03 · what it learned is APPLIED once the car stops', () async {
      // End to end: learning is only worth anything if the stationary reading
      // is corrected by it. This is the reading the driver actually sees.
      final controller = StreamController<GpsSample>();
      final container = _container(storage, controller.stream);
      addTearDown(container.dispose);

      final sub = container.listen(capHeadingProvider, (_, __) {},
          fireImmediately: true);
      addTearDown(sub.close);
      _setTrueNorth(container, true);

      for (var i = 0; i < 30; i++) {
        controller.add(_fix(speed: 20, head: 90, tMs: 1000 + i * 1000));
        await _pump();
      }
      // Stopped: the GPS course is released and the magnetometer takes over.
      for (var i = 0; i < 4; i++) {
        controller.add(_fix(speed: 0, head: 90, tMs: 40000 + i * 1000));
        await _pump();
      }

      expect(container.read(capHeadingProvider), closeTo(90, 2.0),
          reason: 'the magnetometer reads 84 and the learned offset is +6, so '
              'a corrected stationary heading is 90. Showing a bare 84 while '
              'labelled TRUE is the false assertion this path exists to stop');
      expect(container.read(headingSourceProvider), 'TRUE');
    });
  });
}

Future<HeadingCalibrationView> _drive(
  StorageService storage, {
  required bool trueNorth,
}) async {
  final controller = StreamController<GpsSample>();
  final container = _container(storage, controller.stream);
  addTearDown(container.dispose);

  // Exactly what HeadingDisplay does, and nothing more.
  final sub = container.listen(capHeadingProvider, (_, __) {},
      fireImmediately: true);
  addTearDown(sub.close);

  _setTrueNorth(container, trueNorth);

  for (var i = 0; i < 30; i++) {
    controller.add(_fix(speed: 20, head: 90, tMs: 1000 + i * 1000));
    await _pump();
  }
  await controller.close();
  await _pump();

  final cal = container.read(headingCalibrationProvider);
  return HeadingCalibrationView(cal.samples, cal.isLearned, cal.offsetDeg);
}

/// The true-north flag is PERSISTED, and every test here shares one real Hive
/// store, so a blind `toggleTrueNorth()` inherits whatever the previous test
/// left behind. Set it, do not flip it.
void _setTrueNorth(ProviderContainer container, bool want) {
  if (container.read(settingsProvider).useTrueNorth == want) return;
  container.read(settingsProvider.notifier).toggleTrueNorth();
}

class HeadingCalibrationView {
  HeadingCalibrationView(this.samples, this.isLearned, this.offsetDeg);
  final int samples;
  final bool isLearned;
  final double offsetDeg;
}

ProviderContainer _container(StorageService storage, Stream<GpsSample> gps) {
  return ProviderContainer(overrides: [
    gpsRepositoryProvider.overrideWithValue(_FakeGps(gps)),
    // There is no magnetometer under flutter_test. 84 against a GPS course of
    // 90 gives a clean, checkable +6 offset.
    magneticHeadingProvider.overrideWith((ref) => Stream<double>.value(84)),
    storageProvider.overrideWithValue(storage),
  ]);
}

Future<void> _pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

GpsSample _fix({
  double speed = 0,
  double head = double.nan,
  double acc = 4,
  required int tMs,
}) {
  return GpsSample(
    timestamp: DateTime.fromMillisecondsSinceEpoch(tMs),
    latitude: 46.0,
    longitude: 8.0,
    speedMps: speed,
    headingDeg: head,
    accuracyM: acc,
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
