// C0 — a TAP must never zero a trip counter.
//
// This is the most damaging defect found in the production-quality audit, and
// it was in the app from the initial commit. Three things contradicted each
// other:
//
//   * trip_panel.dart bound the reset to `onTap`
//   * the handler was named `_confirmReset` and confirmed nothing
//   * the class doc said "a large value and a reset on long-press"
//
// The tap target is the whole InstrumentBox, which in landscape is roughly 40%
// of the screen. One glove brush on a gravel section zeroed Trip A mid-stage,
// and for a trip computer the trip distance IS the product. Lock mode would
// have prevented it, but lock mode is off by default.
//
// Saam chose long-press, which is what the class doc already promised and what
// real rally tripmeters do.
//
// Test 01 is the regression and MUST fail against the old binding.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/di/providers.dart';
import 'package:irallymeter/core/storage/storage_service.dart';
import 'package:irallymeter/core/theme/app_theme.dart';
import 'package:irallymeter/features/distance/presentation/providers/distance_providers.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';
import 'package:irallymeter/features/dashboard/presentation/widgets/trip_panel.dart';
import 'package:irallymeter/features/trip/domain/trip_state.dart';
import 'package:irallymeter/features/trip/presentation/providers/trip_providers.dart';

void main() {
  late StorageService storage;
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('irallymeter_trip_gesture');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    storage = await StorageService.init();
  });

  tearDownAll(() async => tempDir.delete(recursive: true));

  /// Pumps one Trip A readout with a known non-zero distance already on it.
  Future<ProviderContainer> pumpTrip(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(storage),
        // Both are unbounded periodic streams that outlive the tree and trip
        // the pending-timer check. TripReadout only reads them as a colour and
        // badge input, so pinning them is exactly what dashboard_layout_test
        // does for the same reason.
        gpsDropoutProvider.overrideWith((ref) => Stream<bool>.value(false)),
        displayTickProvider.overrideWith((ref) => Stream<int>.value(0)),
      ],
    );

    // Put real distance on both counters so a reset is observable, and so
    // test 03 can prove the reset is scoped to one of them. `adjust` is the
    // same entry point the on-screen correction pad uses.
    container.read(tripProvider.notifier).adjust(TripCounter.a, 1234.5);
    container.read(tripProvider.notifier).adjust(TripCounter.b, 987.0);
    expect(container.read(tripProvider).tripA, greaterThan(0),
        reason: 'test setup failed — nothing to lose');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.build(DisplayMode.day),
          home: const Scaffold(
            body: SizedBox(
              width: 400,
              height: 200,
              child: TripReadout(counter: TripCounter.a),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  /// Unmount, then dispose the container.
  ///
  /// `resetTrip` settles any outstanding tunnel correction, which instantiates
  /// the distance engine and its 250 ms heartbeat. That timer outlives the
  /// widget tree and trips flutter_test's pending-timer check, so the container
  /// has to be disposed inside the test body rather than in a tearDown that
  /// runs after the check. Same trap AGENTS.md records for the cluster.
  Future<void> finish(WidgetTester tester, ProviderContainer c) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    c.dispose();
  }

  group('C0 · trip reset gesture', () {
    testWidgets('01 · a TAP does NOT reset the trip', (tester) async {
      // THE REGRESSION. Against the old `onTap` binding this fails: the tap
      // zeroes the counter.
      final container = await pumpTrip(tester);
      final before = container.read(tripProvider).tripA;

      await tester.tap(find.byType(TripReadout));
      await tester.pump();

      expect(container.read(tripProvider).tripA, before,
          reason: 'a tap zeroed the trip counter. The tile is ~40% of the '
              'screen in landscape, so this is one glove brush away on every '
              'stage, and the distance is unrecoverable');
      await finish(tester, container);
    });

    testWidgets('02 · a LONG-PRESS does reset the trip', (tester) async {
      // The gesture the class doc always promised.
      final container = await pumpTrip(tester);

      await tester.longPress(find.byType(TripReadout));
      await tester.pump();

      expect(container.read(tripProvider).tripA, 0,
          reason: 'long-press must still reset, or the feature is simply gone');
      await finish(tester, container);
    });

    testWidgets('03 · resetting Trip A leaves Trip B and the odometer alone',
        (tester) async {
      // A reset that took the odometer with it would be worse than the bug.
      final container = await pumpTrip(tester);
      final odoBefore = container.read(tripProvider).odometer;
      final bBefore = container.read(tripProvider).tripB;
      expect(bBefore, greaterThan(0));

      await tester.longPress(find.byType(TripReadout));
      await tester.pump();

      expect(container.read(tripProvider).tripA, 0);
      expect(container.read(tripProvider).tripB, bBefore,
          reason: 'Trip B must survive a Trip A reset');
      expect(container.read(tripProvider).odometer, odoBefore,
          reason: 'the lifetime odometer must survive a trip reset');
      await finish(tester, container);
    });
  });
}
