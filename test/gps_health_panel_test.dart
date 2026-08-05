// C7 — the GNSS HEALTH panel showed a frozen snapshot.
//
// `gpsHealthProvider` is a plain `Provider<GpsHealthStats>` holding a MUTABLE
// object. `gpsStateProvider` mutates it in place on every fix, but the object's
// identity never changes, so the provider never notifies and
// `ref.watch(gpsHealthProvider)` never rebuilds anything.
//
// The panel therefore rendered whatever the counters happened to read at the
// instant the screen opened, and then sat there while the numbers moved
// underneath it. Nothing about it looks stale — it is a live-looking readout of
// dead values.
//
// That is the same class of failure as C2, on the same panel: docs/ROAD-TEST.md
// reads SUSTAINED Hz for §19 row 6 and STREAM STALLS for the [3.15] guarantee,
// and a tester holding this screen open through a tunnel would have watched
// numbers that could not move.
//
// Note a wrapper provider would NOT fix it. Riverpod compares a Provider's new
// value with `==` before notifying, and the value is the same instance, so a
// provider that recomputed on every tick would still notify nobody. The rebuild
// has to be driven by something whose value actually changes, which is what
// `displayTickProvider` already exists for — `measurementStatusProvider` folds
// it in for exactly this reason.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/di/providers.dart';
import 'package:irallymeter/core/storage/storage_service.dart';
import 'package:irallymeter/core/theme/app_theme.dart';
import 'package:irallymeter/features/distance/presentation/providers/distance_providers.dart';
import 'package:irallymeter/features/distance/presentation/section_log_screen.dart';
import 'package:irallymeter/features/gps/domain/gps_repository.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';

void main() {
  late StorageService storage;
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('irallymeter_health');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    storage = await StorageService.init();
  });

  tearDownAll(() async => tempDir.delete(recursive: true));

  group('C7 · the GNSS HEALTH panel is live, not a snapshot', () {
    testWidgets('01 · FIXES moves while the screen stays open', (tester) async {
      // THE REGRESSION. Open the panel on a cold start, drive, and watch the
      // counter that the road test reads sit exactly where it was.
      final gps = StreamController<GpsSample>();
      final ticks = StreamController<int>();
      final container = _container(storage, gps.stream, ticks.stream);

      await _pump(tester, container);

      expect(find.text('3'), findsNothing, reason: 'no fixes yet');

      for (var i = 1; i <= 3; i++) {
        gps.add(_fix(tMs: i * 1000));
        await _settle(tester);
      }
      ticks.add(1);
      await _settle(tester);

      expect(find.text('3'), findsOneWidget,
          reason: 'the panel still read 0 FIXES after three arrived. It is a '
              'live-looking readout of values frozen at the moment the screen '
              'opened, and ROAD-TEST reads two of its fields');

      await _teardown(tester, container, gps, ticks);
    });

    testWidgets('02 · it keeps up on a later tick too', (tester) async {
      // One refresh would be a coincidence. The panel has to track.
      final gps = StreamController<GpsSample>();
      final ticks = StreamController<int>();
      final container = _container(storage, gps.stream, ticks.stream);

      await _pump(tester, container);

      for (var i = 1; i <= 3; i++) {
        gps.add(_fix(tMs: i * 1000));
        await _settle(tester);
      }
      ticks.add(1);
      await _settle(tester);
      expect(find.text('3'), findsOneWidget);

      for (var i = 4; i <= 7; i++) {
        gps.add(_fix(tMs: i * 1000));
        await _settle(tester);
      }
      ticks.add(2);
      await _settle(tester);

      expect(find.text('7'), findsOneWidget,
          reason: 'the panel refreshed once and then went stale again');

      await _teardown(tester, container, gps, ticks);
    });
  });
}

ProviderContainer _container(
  StorageService storage,
  Stream<GpsSample> gps,
  Stream<int> ticks,
) {
  final container = ProviderContainer(overrides: [
    storageProvider.overrideWithValue(storage),
    gpsRepositoryProvider.overrideWithValue(_FakeGps(gps)),
    // An unbounded Stream.periodic outlives the widget tree and trips the
    // pending-timer check — the same reason gpsDropoutProvider is pinned in
    // dashboard_layout_test.
    displayTickProvider.overrideWith((ref) => ticks),
  ]);
  // app.dart keeps the GPS pipeline alive app-wide; without this nothing folds
  // the fixes into the health stats and the test would prove only that the
  // panel renders zeros.
  container.listen(gpsStateProvider, (_, __) {}, fireImmediately: true);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(465.5, 1038.5);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.build(DisplayMode.day),
        home: const SectionLogScreen(),
      ),
    ),
  );
  await tester.pump();
}

/// The distance engine starts a 250 ms heartbeat the moment it is built, and
/// `estimatedSectionsProvider` builds it. A container disposed in `addTearDown`
/// is disposed AFTER the test body ends, so flutter_test sees that timer still
/// pending and fails the test for it rather than for its assertion. Dispose
/// inside the body.
Future<void> _teardown(
  WidgetTester tester,
  ProviderContainer container,
  StreamController<GpsSample> gps,
  StreamController<int> ticks,
) async {
  await _unmount(tester);
  await gps.close();
  await ticks.close();
  container.dispose();
}

/// A stream event reaches its provider in a MICROTASK, and a single
/// `tester.pump()` runs the frame before that microtask has fired. Two pumps:
/// the first delivers, the second rebuilds. This bit me writing the test and it
/// looked exactly like the bug under test.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

GpsSample _fix({required int tMs}) => GpsSample(
      timestamp: DateTime.fromMillisecondsSinceEpoch(tMs),
      latitude: 46.0,
      longitude: 8.0,
      speedMps: 10,
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
