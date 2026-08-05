// C1 — the GPS/magnetometer switch, which had ZERO coverage and was broken.
//
// `capHeadingProvider` is documented as a hybrid: GPS course-over-ground while
// moving (true-north referenced, stable near steel), magnetometer while
// stationary. It was not a hybrid. It was a ONE-WAY LATCH.
//
// `gps_providers.dart` only ever ASSIGNED `smoothedHeading` — there was no
// `else`, and the provider is not autoDispose, so after the first fix above the
// threshold the GPS heading stayed finite for the rest of the app's life and
// `capHeadingProvider`'s magnetometer branch became unreachable. At a
// standstill the cluster showed a STALE FROZEN COURSE still labelled `GPS`.
//
// That is worse than the flapping this was originally checked for: a wrong
// heading that asserts it is right. The existing gps_system_test 18 passes
// because it never acquires a heading in the first place; nothing covered
// acquire-then-stop.
//
// Fixing it naively would introduce the flapping, so the release threshold is
// deliberately lower than the acquire threshold. Test 03 pins that.

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
import 'package:irallymeter/features/gps/domain/gps_state.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';

void main() {
  late StorageService storage;
  late Directory tempDir;

  // headingSourceProvider reads the true-north setting, which is backed by
  // Hive, so this one test needs real storage.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('irallymeter_heading_src');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    storage = await StorageService.init();
  });

  tearDownAll(() async => tempDir.delete(recursive: true));

  group('C1 · heading source selection', () {
    test('01 · a stop RELEASES the GPS course instead of freezing it',
        () async {
      // THE REGRESSION. Drive north at 10 m/s, then stop dead. Before the fix
      // the heading stayed 90 forever and the label stayed GPS.
      final r = await _run([
        _fix(speed: 10, head: 90, tMs: 1000),
        _fix(speed: 10, head: 90, tMs: 2000),
        _fix(speed: 10, head: 90, tMs: 3000),
        // Stopped. GNSS course is meaningless here.
        _fix(speed: 0.0, head: 90, tMs: 4000),
        _fix(speed: 0.0, head: 90, tMs: 5000),
      ]);

      expect(r.last.headingDeg.isNaN, isTrue,
          reason: 'the GPS course was still being reported while stopped. '
              'GNSS course is meaningless below walking pace, so this is a '
              'stale value presented as current — the cluster asserts a '
              'heading it cannot know');
    });

    test('02 · while genuinely moving the GPS course IS used', () async {
      // The other half: releasing must not break the normal case.
      final r = await _run([
        _fix(speed: 10, head: 90, tMs: 1000),
        _fix(speed: 10, head: 90, tMs: 2000),
      ]);
      expect(r.last.headingDeg.isFinite, isTrue);
      expect(r.last.headingDeg, closeTo(90, 1.0));
    });

    test('03 · HYSTERESIS — hovering at the threshold must not flap', () async {
      // Crawling in traffic sits right on the boundary. A single threshold
      // would toggle the source on every fix, which on a driver-facing compass
      // reads as a fault. Acquire is deliberately higher than release.
      final r = await _run([
        _fix(speed: 10, head: 90, tMs: 1000), // acquire
        _fix(speed: 1.1, head: 90, tMs: 2000), // in the band
        _fix(speed: 0.9, head: 90, tMs: 3000), // in the band
        _fix(speed: 1.2, head: 90, tMs: 4000), // in the band
        _fix(speed: 1.0, head: 90, tMs: 5000), // in the band
      ]);

      final tail = r.skip(1).map((s) => s.headingDeg.isNaN).toSet();
      expect(tail.length, 1,
          reason: 'the source flipped between GPS and magnetic while the car '
              'crawled at a steady speed — that is the boundary flapping the '
              'hysteresis band exists to prevent');
      expect(r.last.headingDeg.isFinite, isTrue,
          reason: 'inside the band the previous source should persist, and '
              'the previous source here was GPS');
    });

    test('04 · after a stop, moving again RE-ACQUIRES the course', () async {
      // The latch made this untestable: it never released, so it never had to
      // re-acquire.
      final r = await _run([
        _fix(speed: 10, head: 90, tMs: 1000),
        _fix(speed: 0.0, head: 90, tMs: 2000), // release
        _fix(speed: 10, head: 270, tMs: 3000), // moving again, new direction
        _fix(speed: 10, head: 270, tMs: 4000),
      ]);

      expect(r.last.headingDeg.isFinite, isTrue,
          reason: 'the course must come back when the car moves again');
      expect(r.last.headingDeg, closeTo(270, 1.0),
          reason: 're-acquisition must adopt the NEW direction, not smooth up '
              'from the stale pre-stop value');
    });

    test('05 · the SOURCE LABEL follows the switch, not just the value',
        () async {
      // headingSourceProvider is what the driver actually reads. If the value
      // releases but the label still says GPS, nothing has been fixed.
      final container = ProviderContainer(overrides: [
        gpsRepositoryProvider.overrideWithValue(
          _FakeGps(Stream<GpsSample>.fromIterable([
            _fix(speed: 10, head: 90, tMs: 1000),
            _fix(speed: 0.0, head: 90, tMs: 2000),
          ])),
        ),
        // No magnetometer in a test: pin it so the fallback is deterministic.
        magneticHeadingProvider.overrideWith((ref) => Stream<double>.value(42)),
        storageProvider.overrideWithValue(storage),
      ]);
      addTearDown(container.dispose);

      final sub = container.listen(gpsStateProvider, (_, __) {},
          fireImmediately: true);
      addTearDown(sub.close);
      // C9 exposed a hole in this setup rather than in the assertion. Nothing
      // here watched capHeadingProvider, so magneticHeadingProvider was never
      // created and its 42 never arrived — the container had no magnetic
      // reading at all, and only the old code's missing "no source" branch made
      // that look like MAG. HeadingDisplay watches this from app start, so the
      // test now does too. The assertion below is UNCHANGED.
      final capSub = container.listen(capHeadingProvider, (_, __) {},
          fireImmediately: true);
      addTearDown(capSub.close);
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(container.read(headingSourceProvider), 'MAG',
          reason: 'the cluster still claimed GPS while stopped, which is the '
              'false assertion this whole path was written to avoid');
    });
  });
}

Future<List<GpsState>> _run(List<GpsSample> fixes) async {
  final controller = StreamController<GpsSample>();
  final container = ProviderContainer(overrides: [
    gpsRepositoryProvider.overrideWithValue(_FakeGps(controller.stream)),
  ]);
  addTearDown(container.dispose);

  final emitted = <GpsState>[];
  final sub = container.listen<AsyncValue<GpsState>>(
    gpsStateProvider,
    (_, next) {
      final v = next.valueOrNull;
      if (v != null) emitted.add(v);
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
  return emitted;
}

Future<void> _pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

GpsSample _fix({
  double lat = 46.0,
  double lon = 8.0,
  double speed = 0,
  double head = double.nan,
  double acc = 4,
  required int tMs,
}) {
  return GpsSample(
    timestamp: DateTime.fromMillisecondsSinceEpoch(tMs),
    latitude: lat,
    longitude: lon,
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
