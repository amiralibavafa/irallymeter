// Widget tests for the DASHBOARD LAYOUT at real device sizes.
//
// Why these exist: the cluster is a fixed, non-scrolling instrument panel, so a
// RenderFlex overflow is not cosmetic — it means a co-driver cannot read a trip
// distance mid-stage. Adding the tunnel controls squeezed the instruments
// column, which unit tests can't see. These pin the layout at the sizes the app
// actually runs at, in both orientations.
//
// Note on timers: the cluster is full of live widgets (AppClock, the distance
// engine's heartbeat, the tunnel leg's ticker), so `pumpAndSettle` would never
// settle. Each test pumps once, captures any layout exception, then unmounts the
// tree so every timer is cancelled before the test ends.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/di/providers.dart';
import 'package:irallymeter/core/storage/storage_service.dart';
import 'package:irallymeter/core/theme/app_theme.dart';
import 'package:irallymeter/features/dashboard/presentation/dashboard_screen.dart';
import 'package:irallymeter/features/distance/domain/motion_repository.dart';
import 'package:irallymeter/features/distance/domain/motion_sample.dart';
import 'package:irallymeter/features/distance/presentation/providers/distance_providers.dart';
import 'package:irallymeter/features/gps/domain/gps_repository.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';

void main() {
  late StorageService storage;
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('irallymeter_layout_test');

    // Hive needs a documents directory; give it a throwaway one so the cluster
    // can boot for real rather than against a stubbed settings layer.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    storage = await StorageService.init();
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  // Real logical sizes: a Pixel-class phone (2856×1280 @ 2.75) — the device the
  // cluster was verified on — and a smaller 5" phone as the tight case.
  const pixelLandscape = Size(1038.5, 465.5);
  const pixelPortrait = Size(465.5, 1038.5);
  const smallLandscape = Size(800, 360);

  group('DASHBOARD · layout', () {
    testWidgets('01 · landscape (co-driver) renders without overflow',
        (tester) async {
      await _pumpDashboard(tester, storage, pixelLandscape);
      await _expectNoOverflow(tester);
    });

    // UNSKIPPED in [SA-V2] by P2, and the assertion is UNCHANGED. This was
    // amir's own skip for a real, pre-existing overflow: the clock (~88) +
    // status badge + five 48 px nav targets (240) exceed a 465 px width, and it
    // grew to 137 px in Estimation Mode because the badge text is longer there.
    // Portrait now stacks the nav row under the clock/status row instead of
    // shrinking the glove-sized targets or ellipsising the status. See the
    // _TopBar doc comment for why every one-row fix was rejected.
    testWidgets('02 · portrait renders without overflow', (tester) async {
      await _pumpDashboard(tester, storage, pixelPortrait);
      await _expectNoOverflow(tester);
    });

    testWidgets('02b · portrait survives the LONGEST status text', (tester) async {
      // The worst case measured on device: 137 px of overflow, because
      // "TUNNEL · EST 0.00" is far wider than "GPS ±5m". Fixing portrait at
      // rest would be worthless if it broke again the moment the app entered a
      // tunnel — which is the one state where the co-driver is reading it.
      await _pumpDashboard(tester, storage, pixelPortrait,
          settle: const Duration(seconds: 4));
      expect(find.textContaining('TUNNEL'), findsWidgets,
          reason: 'the engine should have entered Tunnel Mode by now');
      await _expectNoOverflow(tester);
    });

    testWidgets('02c · portrait keeps all five nav targets at glove size',
        (tester) async {
      // The rejected one-row fixes all worked by shrinking these or hiding them
      // behind a menu. If a later change quietly does that, this fails.
      await _pumpDashboard(tester, storage, pixelPortrait);
      final buttons = find.byType(IconButton);
      expect(tester.widgetList(buttons).length, 5);
      for (final e in buttons.evaluate()) {
        final size = tester.getSize(find.byWidget(e.widget));
        expect(size.width, greaterThanOrEqualTo(48.0));
        expect(size.height, greaterThanOrEqualTo(48.0));
      }
      await _expectNoOverflow(tester);
    });

    testWidgets('03 · a small landscape phone renders without overflow',
        (tester) async {
      await _pumpDashboard(tester, storage, smallLandscape);
      await _expectNoOverflow(tester);
    });

    // '04 · the tunnel control is reachable on the cluster' removed in
    // [3.4b]: SPEC-v2 §15 deletes the manual tunnel control it asserted on.

    testWidgets('05 · the status bar stays inside the top bar once Tunnel Mode '
        'lengthens its text', (tester) async {
      // "TUNNEL · EST 0.00" is markedly wider than "GPS ±5m", so the badge must
      // give way rather than push the nav icons off the top bar. Drives the
      // REAL detector: one good fix, then let the engine's heartbeat run past
      // the confirm delay with no further fixes.
      await _pumpDashboard(tester, storage, pixelLandscape,
          settle: const Duration(seconds: 4));
      expect(find.textContaining('TUNNEL'), findsWidgets,
          reason: 'the engine should have entered Tunnel Mode by now');
      await _expectNoOverflow(tester);
    },
        // SKIPPED IN [3.4b], AND THE REASON IS A FINDING, NOT A CHORE.
        //
        // This test was passing VACUOUSLY. `find.textContaining('TUNNEL')` was
        // matching the TunnelControls button label — the manual control SPEC-v2
        // §15 removes — not the status bar's "TUNNEL · EST". With that widget
        // gone the finder fails, which exposes that the engine was never in
        // Tunnel Mode here at all.
        //
        // It cannot be: DistanceEngineController drives `tick(DateTime.now())`,
        // a WALL clock, while `tester.pump(Duration)` advances only the fake
        // async clock. No amount of pumping moves `DateTime.now()`, so the
        // dropout detector can never fire inside a widget test. The engine
        // itself takes `now` as a parameter and is fully testable (see
        // estimation_thresholds_test.dart); it is the PROVIDER that hard-codes
        // the clock.
        //
        // The risk it describes is real and was observed on device: the top-bar
        // overflow grew from 70 px to 79 px when the status text changed from
        // "GPS ±5m" to "GPS SYNC" (/tmp/shots/09). Restoring this test means
        // injecting a clock into DistanceEngineController — a Phase 4 item, not
        // something to bury inside a spec-compliance step.
        // RESTORED in [SA-V2] by P8: the clock is injectable now, so the
        // engine really does enter Estimation Mode here and the finder matches
        // the STATUS BAR rather than a button that no longer exists.
        );
  });
}

/// Builds the real dashboard against fake GPS/motion sources.
Future<void> _pumpDashboard(
  WidgetTester tester,
  StorageService storage,
  Size logicalSize, {
  Duration settle = Duration.zero,
}) async {
  // P8: the engine's clock is now injectable, so a widget test can actually
  // reach Estimation Mode. `tester.pump(Duration)` advances only the fake async
  // clock, so a hard-coded `DateTime.now()` could never be moved from here.
  var fakeNow = DateTime.utc(2026);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logicalSize;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        gpsRepositoryProvider.overrideWithValue(_FakeGps(_oneFix())),
        motionRepositoryProvider.overrideWithValue(_SilentMotion()),
        // The 1 Hz dropout watchdog is an unbounded Stream.periodic that
        // outlives the tree teardown and trips the pending-timer check. Its
        // behaviour is covered by gps_system_test; here it is only a colour
        // input to the layout, so pin it.
        gpsDropoutProvider.overrideWith((ref) => Stream<bool>.value(false)),
        // Same reason: the §5.1 display heartbeat is an unbounded periodic
        // stream. Pin it so it cannot outlive the tree.
        displayTickProvider.overrideWith((ref) => Stream<int>.value(0)),
        engineClockProvider.overrideWithValue(() => fakeNow),
      ],
      child: MaterialApp(
        theme: AppTheme.build(DisplayMode.day),
        home: const DashboardScreen(),
      ),
    ),
  );
  await tester.pump();
  if (settle > Duration.zero) {
    // Move the ENGINE's clock as well as the widget clock, so the dropout
    // detector sees the silence it is being asked to notice.
    fakeNow = fakeNow.add(settle);
    await tester.pump(settle);
  }
}

/// Captures any layout exception, then unmounts so the cluster's live timers
/// (clock, engine heartbeat, tunnel ticker) are cancelled before the test ends.
Future<void> _expectNoOverflow(WidgetTester tester) async {
  final error = tester.takeException();
  // Unmount, then pump again so ProviderScope's disposal actually runs and
  // cancels the engine heartbeat / dropout watchdog / clock timers.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  expect(
    error,
    isNull,
    reason: 'the cluster does not scroll — an overflow means an instrument is '
        'unreadable, not merely ugly',
  );
}

Stream<GpsSample> _oneFix() => Stream<GpsSample>.value(GpsSample(
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      latitude: 46.0,
      longitude: 8.0,
      speedMps: 0,
      headingDeg: double.nan,
      accuracyM: 5,
      altitudeM: 0,
      hasFix: true,
    ));

class _FakeGps implements GpsRepository {
  _FakeGps(this._stream);
  final Stream<GpsSample> _stream;

  @override
  Future<bool> ensurePermission() async => true;
  @override
  Stream<GpsSample> positionStream() => _stream;
  @override
  Future<GpsSample?> lastKnown() async => null;
}

class _SilentMotion implements MotionRepository {
  @override
  Stream<MotionSample> motionStream() => const Stream<MotionSample>.empty();
}
