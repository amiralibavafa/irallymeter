// Stage 3 — HeadingDisplay had ZERO widget coverage.
//
// Five findings in this pass changed what this one tile says: C1 (the source
// was a one-way latch), C4 (the calibration never learned), C5 (TRUE was not
// earned), C9 (there was no "no source" state) and C10 (the smoothing). Every
// one of them was verified at the PROVIDER level. Nothing checked that the
// values reach the screen, or that the screen renders the honest placeholder
// when there is no heading to show.
//
// That gap is not theoretical here. The whole point of the C9 work is a LABEL,
// and a label is a widget concern: a provider returning '--' is worth nothing
// if the tile still draws a live-looking compass rose beside it. Test 04 is
// the one that would have caught that.
//
// These drive the real providers from a fake GPS stream and a fake
// magnetometer, exactly as the provider tests do, and then assert on rendered
// text. Overriding capHeadingProvider directly would have tested nothing.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/di/providers.dart';
import 'package:irallymeter/core/storage/storage_service.dart';
import 'package:irallymeter/core/theme/app_theme.dart';
import 'package:irallymeter/features/compass/presentation/providers/compass_providers.dart';
import 'package:irallymeter/features/dashboard/presentation/widgets/heading_display.dart';
import 'package:irallymeter/features/gps/domain/gps_repository.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';

void main() {
  late StorageService storage;
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('irallymeter_headingui');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    storage = await StorageService.init();
  });

  tearDownAll(() async => tempDir.delete(recursive: true));

  group('HeadingDisplay · what the driver actually reads', () {
    testWidgets('01 · moving shows the course and says GPS', (tester) async {
      final h = await _mount(tester, storage, magnetometer: true, fixes: [
        _fix(speed: 20, head: 90, tMs: 1000),
        _fix(speed: 20, head: 90, tMs: 2000),
      ]);

      expect(find.text('CAP  •  GPS'), findsOneWidget);
      expect(find.text('090'), findsOneWidget,
          reason: 'the course reached the provider but not the tile');
      expect(find.text('E'), findsOneWidget, reason: 'cardinal for 090');
      expect(_painter(tester).active, isTrue);
      await h();
    });

    testWidgets('02 · stopped falls back to the magnetometer and says MAG',
        (tester) async {
      // C1's release, seen from the outside. Before that fix this tile showed a
      // stale frozen course still labelled GPS.
      final h = await _mount(tester, storage, magnetometer: true, fixes: [
        _fix(speed: 20, head: 90, tMs: 1000),
        _fix(speed: 0, head: 90, tMs: 2000),
      ]);

      expect(find.text('CAP  •  MAG'), findsOneWidget,
          reason: 'a stopped car cannot know its course over ground, so the '
              'tile must stop claiming GPS');
      expect(find.text('084'), findsOneWidget,
          reason: 'the magnetometer reads 84 and true north is off, so 84 is '
              'the honest number to show');
      await h();
    });

    testWidgets('03 · NO magnetometer renders the placeholder, not a number',
        (tester) async {
      // C9 at the level that matters. The provider returning '--' is only half
      // of it; the tile has to show that it knows nothing.
      final h = await _mount(tester, storage, magnetometer: false, fixes: [
        _fix(speed: 20, head: 90, tMs: 1000),
        _fix(speed: 0, head: 90, tMs: 2000),
      ]);

      expect(find.text('CAP  •  --'), findsOneWidget,
          reason: 'the tile named a sensor that was supplying nothing');
      expect(find.text('---'), findsOneWidget);
      expect(find.text('--'), findsOneWidget, reason: 'cardinal placeholder');
      expect(find.text('000'), findsNothing,
          reason: 'a heading of 000 would be a claim; --- is the truth');
      await h();
    });

    testWidgets('04 · with no heading the ROSE goes inactive too',
        (tester) async {
      // THE ONE A PROVIDER TEST CANNOT REACH. An honest label beside a
      // live-looking compass rose is still a lie, and the rose is drawn by a
      // CustomPainter that takes `active` separately from the value.
      final h = await _mount(tester, storage, magnetometer: false, fixes: [
        _fix(speed: 20, head: 90, tMs: 1000),
        _fix(speed: 0, head: 90, tMs: 2000),
      ]);

      expect(_painter(tester).active, isFalse,
          reason: 'the needle and the north marker were still being drawn '
              'while the tile had no heading at all. The painter skips both '
              'when inactive — this pins that it is actually told');
      await h();
    });
  });
}

/// The painter is private, so read it off the widget rather than importing it.
dynamic _painter(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(HeadingDisplay),
      matching: find.byType(CustomPaint),
    ).first,
  );
  return paint.painter;
}

/// Mounts the tile on a real provider graph. Returns the teardown, which must
/// run INSIDE the test body: gpsStateProvider and the calibration both hold
/// subscriptions that outlive `addTearDown`.
Future<Future<void> Function()> _mount(
  WidgetTester tester,
  StorageService storage, {
  required bool magnetometer,
  required List<GpsSample> fixes,
}) async {
  final controller = StreamController<GpsSample>();
  final container = ProviderContainer(overrides: [
    storageProvider.overrideWithValue(storage),
    gpsRepositoryProvider.overrideWithValue(_FakeGps(controller.stream)),
    magneticHeadingProvider.overrideWith((ref) => magnetometer
        ? Stream<double>.value(84)
        : const Stream<double>.empty()),
  ]);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.build(DisplayMode.day),
        home: const Scaffold(body: HeadingDisplay()),
      ),
    ),
  );
  await tester.pump();

  for (final f in fixes) {
    controller.add(f);
    // A stream event reaches its provider in a MICROTASK, so one pump would
    // run the frame before delivery.
    await tester.pump();
    await tester.pump();
  }

  return () async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    await controller.close();
    container.dispose();
  };
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
