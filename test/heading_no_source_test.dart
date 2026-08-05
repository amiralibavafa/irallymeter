// C9 — the cluster claimed a source it did not have.
//
// `headingSourceProvider` could only ever return GPS, MAG or TRUE:
//
//     if (headingProvider.isFinite) return 'GPS';
//     if (!wantsTrue) return 'MAG';
//     return calibration.isLearned ? 'TRUE' : 'MAG';
//
// There is no branch for "neither". On a phone with no magnetometer, or before
// the sensor's first event has arrived, `capHeadingProvider` returns NaN and
// `HeadingDisplay` correctly renders `---`, while the label beside it read
// `CAP • MAG`. So the tile said the magnetic compass was supplying a value it
// was not supplying.
//
// That is the same false assertion the `TRUE` label was rewritten to remove,
// one step further down: it is not enough to stop claiming the reading is
// true-north referenced if the app still claims to know where the reading came
// from. Not every Android handset has a magnetometer, and the ones that omit it
// are the cheap ones a rally crew is most likely to use as a spare.

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

void main() {
  late StorageService storage;
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('irallymeter_nosource');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    storage = await StorageService.init();
  });

  tearDownAll(() async => tempDir.delete(recursive: true));

  group('C9 · no source is its own state', () {
    test('01 · a phone with NO magnetometer does not claim MAG', () async {
      // THE REGRESSION. Stopped, so there is no GPS course, and the sensor
      // never emits. The value is correctly '---' and the label said MAG.
      final container = await _stopped(storage, magnetometer: false);

      expect(container.read(capHeadingProvider).isNaN, isTrue,
          reason: 'there is genuinely no heading available here');
      expect(container.read(headingSourceProvider), '--',
          reason: 'the tile read CAP • MAG next to a value of ---, so it named '
              'a sensor that supplied nothing. Not every handset has a '
              'magnetometer');
      container.dispose();
    });

    test('02 · with a magnetometer it still says MAG', () async {
      // The fix must not turn the normal stationary case into a shrug.
      final container = await _stopped(storage, magnetometer: true);

      expect(container.read(capHeadingProvider).isFinite, isTrue);
      expect(container.read(headingSourceProvider), 'MAG');
      container.dispose();
    });

    test('03 · while moving it is still GPS, magnetometer or not', () async {
      // The GPS branch is upstream of all of this and must be unaffected.
      final container = _container(storage, magnetometer: false);
      final sub = container.listen(gpsStateProvider, (_, __) {},
          fireImmediately: true);
      container.read(_gpsSink).add(_fix(speed: 20, tMs: 1000));
      await _pump();

      expect(container.read(headingSourceProvider), 'GPS');
      sub.close();
      container.dispose();
    });
  });
}

/// A stationary car: the GPS course is released, so the magnetic branch is the
/// only one left.
Future<ProviderContainer> _stopped(
  StorageService storage, {
  required bool magnetometer,
}) async {
  final container = _container(storage, magnetometer: magnetometer);
  final sub = container.listen(gpsStateProvider, (_, __) {},
      fireImmediately: true);
  addTearDown(sub.close);
  // HeadingDisplay watches this from app start. Without it the magnetometer
  // provider is only created at assertion time and is still loading, which
  // looks exactly like the missing-sensor case under test.
  final capSub = container.listen(capHeadingProvider, (_, __) {},
      fireImmediately: true);
  addTearDown(capSub.close);

  container.read(_gpsSink).add(_fix(speed: 20, tMs: 1000)); // acquire
  await _pump();
  container.read(_gpsSink).add(_fix(speed: 0, tMs: 2000)); // release
  await _pump();
  await _pump();
  return container;
}

/// Holds the controller so a test can push fixes after the container is built.
final _gpsSink = Provider<StreamController<GpsSample>>(
    (ref) => throw UnimplementedError('overridden per test'));

ProviderContainer _container(
  StorageService storage, {
  required bool magnetometer,
}) {
  final controller = StreamController<GpsSample>();
  addTearDown(controller.close);
  return ProviderContainer(overrides: [
    storageProvider.overrideWithValue(storage),
    _gpsSink.overrideWithValue(controller),
    gpsRepositoryProvider.overrideWithValue(_FakeGps(controller.stream)),
    // An empty stream is exactly what a handset with no magnetometer produces:
    // the provider stays in its initial state and `valueOrNull` is null.
    magneticHeadingProvider.overrideWith((ref) => magnetometer
        ? Stream<double>.value(84)
        : const Stream<double>.empty()),
  ]);
}

Future<void> _pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

GpsSample _fix({required double speed, required int tMs}) => GpsSample(
      timestamp: DateTime.fromMillisecondsSinceEpoch(tMs),
      latitude: 46.0,
      longitude: 8.0,
      speedMps: speed,
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
