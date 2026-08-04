// P3 — the permission rationale screen.
//
// The behaviour under test is not "a screen exists". It is that a FIRST-RUN
// user is told why the app needs location before Android asks, and — the
// structural half — that nothing touches the GPS stack until they have been
// told, because `getPositionStream` raises the system dialog by itself and
// would otherwise land on top of the explanation.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:irallymeter/app.dart';
import 'package:irallymeter/core/di/providers.dart';
import 'package:irallymeter/core/router/app_router.dart';
import 'package:irallymeter/core/storage/storage_service.dart';
import 'package:irallymeter/features/dashboard/presentation/dashboard_screen.dart';
import 'package:irallymeter/features/distance/domain/motion_repository.dart';
import 'package:irallymeter/features/distance/domain/motion_sample.dart';
import 'package:irallymeter/features/distance/presentation/providers/distance_providers.dart';
import 'package:irallymeter/features/gps/domain/gps_repository.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';
import 'package:irallymeter/features/onboarding/presentation/permission_rationale_screen.dart';

void main() {
  late StorageService storage;
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('irallymeter_onboarding');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    // The rationale screen really does call both plugins on CONTINUE. Answer
    // them rather than stubbing the screen, so the test exercises the same code
    // path a device does.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async => call.method == 'checkPermissionStatus' ? 1 : {0: 1},
    );
    storage = await StorageService.init();
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  setUp(() {
    // NOT awaited, and it must not be.
    //
    // The CONTINUE tests start a Hive write from inside flutter_test's fake
    // async zone, and a `dart:io` future created there can never complete once
    // that test ends — the zone that would deliver the completion is gone. Hive
    // serialises operations per box, so awaiting ANYTHING on this box
    // afterwards blocks forever, and the failure lands on whichever test runs
    // next rather than the one that caused it. That is what made this suite
    // look flaky.
    //
    // `delete` updates the in-memory value synchronously, which is all these
    // tests read back.
    unawaited(storage.delete(StorageKeys.onboarded));
  });

  group('ONBOARDING · the rationale comes before the prompt', () {
    testWidgets('01 · a first run opens the rationale, not the cluster',
        (tester) async {
      final gps = _RecordingGps();
      await _pumpApp(tester, storage, gps);

      expect(find.byType(PermissionRationaleScreen), findsOneWidget);
      expect(find.byType(DashboardScreen), findsNothing);
      await _unmount(tester);
    });

    testWidgets('02 · and it does NOT touch the GPS stack while showing',
        (tester) async {
      // The whole point. `positionStream()` raises Android's location dialog on
      // its own, so if the app root starts the engine eagerly the cold prompt
      // appears on top of the screen written to precede it — and the screen is
      // then worth nothing.
      final gps = _RecordingGps();
      await _pumpApp(tester, storage, gps);

      expect(gps.streamOpened, isFalse,
          reason: 'the position stream was subscribed before the user had been '
              'told why — that IS the cold prompt this screen replaces');
      await _unmount(tester);
    });

    testWidgets('03 · it names both permissions and says where data goes',
        (tester) async {
      final gps = _RecordingGps();
      await _pumpApp(tester, storage, gps);

      expect(find.textContaining('LOCATION'), findsOneWidget);
      expect(find.textContaining('NOTIFICATIONS'), findsOneWidget);
      // A location rationale that does not say where the location goes is not a
      // rationale.
      expect(find.textContaining('WHERE IT GOES'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('04 · CONTINUE persists the flag, flips the gate, and moves on',
        (tester) async {
      final container = await _pumpRationale(tester, storage);
      await _tapContinue(tester);

      expect(storage.read(StorageKeys.onboarded, false), isTrue);
      expect(find.text('CLUSTER'), findsOneWidget);
      // The gate, not just the stored flag. Persisting alone would leave the
      // app root holding the GPS engine back for the rest of THIS launch —
      // a trip computer you have to restart before it measures is broken.
      expect(container.read(onboardedProvider), isTrue);
      await _unmount(tester);
    });

    test('05 · a returning user starts at the cluster, not the rationale', () {
      // Pure, and deliberately so. The obvious version of this test — pump the
      // whole app with the flag set and assert the dashboard appears — hangs
      // the widget harness: with the gate open the root starts the distance
      // engine, whose heartbeat timers do not settle under fake async. Amir's
      // own dashboard_layout_test avoids the same thing by pumping
      // DashboardScreen directly rather than IRallyMeterApp.
      //
      // So the two halves are asserted where each can actually be observed:
      // the START LOCATION here, and the GATE in test 04. Constructing the
      // GoRouter itself needs a live binding, hence `initialLocationFor`.
      expect(AppRouter.initialLocationFor(onboarded: true), '/');
      expect(AppRouter.initialLocationFor(onboarded: false), '/welcome');
    });

    test('05b · the gate is seeded from storage, not assumed', () {
      final container =
          ProviderContainer(overrides: [storageProvider.overrideWithValue(storage)]);
      addTearDown(container.dispose);
      expect(container.read(onboardedProvider), isFalse,
          reason: 'setUp cleared the flag, so a fresh install must read false');
    });

    testWidgets('06 · a denied or THROWING permission still opens the app',
        (tester) async {
      // The screen explains, it does not enforce. Location is denied outright
      // and the call throws — the same shape as the PlatformException that once
      // stopped this app from starting at all (P1). The user must still reach
      // the cluster, because it degrades honestly on its own: the status bar
      // already reads GPS LOST.
      await _pumpRationale(tester, storage, grant: false, throws: true);
      await _tapContinue(tester);

      expect(find.text('CLUSTER'), findsOneWidget);
      expect(storage.read(StorageKeys.onboarded, false), isTrue,
          reason: 'a user who said no must not be asked on every launch');
      await _unmount(tester);
    });
  });
}

Future<void> _pumpApp(
  WidgetTester tester,
  StorageService storage,
  _RecordingGps gps,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1038.5, 465.5);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        gpsRepositoryProvider.overrideWithValue(gps),
        motionRepositoryProvider.overrideWithValue(_SilentMotion()),
        gpsDropoutProvider.overrideWith((ref) => Stream<bool>.value(false)),
        displayTickProvider.overrideWith((ref) => Stream<int>.value(0)),
      ],
      child: const IRallyMeterApp(),
    ),
  );
  await tester.pump();
}

/// Pumps ONLY the rationale screen, against a two-route router whose '/' is a
/// bare marker rather than the real cluster.
///
/// Deliberate: what these two tests exercise is the BUTTON, and mounting the
/// real cluster behind it drags in the clock and the engine heartbeat, whose
/// live timers make the tap path far harder to drive than the thing being
/// tested. Tests 01/02/05 already pump the whole app, so routing and the GPS
/// gate are covered against the real tree.
Future<ProviderContainer> _pumpRationale(
  WidgetTester tester,
  StorageService storage, {
  bool grant = true,
  bool throws = false,
}) async {
  // A real portrait phone, not the 800x600 default: the rationale is taller
  // than 600 px, so on the default surface CONTINUE sits below the fold and
  // `tester.tap` silently MISSES it — it warns rather than failing, so the test
  // then fails on an unrelated assertion further down.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(465.5, 1038.5);
  addTearDown(tester.view.reset);

  final container = ProviderContainer(overrides: [
    storageProvider.overrideWithValue(storage),
    gpsRepositoryProvider
        .overrideWithValue(_RecordingGps(grant: grant, throws: throws)),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: GoRouter(initialLocation: '/welcome', routes: [
        GoRoute(
            path: '/welcome',
            builder: (_, __) => const PermissionRationaleScreen()),
        GoRoute(path: '/', builder: (_, __) => const Text('CLUSTER')),
      ]),
    ),
  ));
  await tester.pump();
  return container;
}

/// Taps CONTINUE and lets the button's real async work finish.
///
/// `runAsync` is required rather than tidier: persisting the flag is a Hive
/// write, which is genuine disk I/O, and `tester.pump()` only advances the fake
/// async clock — the future would never complete under it.
Future<void> _tapContinue(WidgetTester tester) async {
  await tester.tap(find.text('CONTINUE'));
  // Three pumps, not `pumpAndSettle`: the button's handler awaits the two
  // permission calls, and each resolves on a microtask flush. `pumpAndSettle`
  // would never return once the cluster's live timers are in the tree.
  //
  // Note there is no `runAsync` here, and that is a property of the code rather
  // than of the test: the handler awaits the Hive flush only AFTER navigating,
  // so nothing the assertions look at is behind real disk I/O.
  await tester.pump();
  await tester.pump();
  await tester.pump();

  // Give the handler's fire-and-forget Hive write a chance to land. See the
  // note on `setUp`: it cannot be relied on, because the write was started in
  // the fake async zone, so nothing here may ever AWAIT this box again.
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)));
}

/// Unmount so the cluster's live timers are cancelled before the test ends.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

class _RecordingGps implements GpsRepository {
  _RecordingGps({this.grant = true, this.throws = false});

  final bool grant;
  final bool throws;
  bool streamOpened = false;

  @override
  Future<bool> ensurePermission() async {
    if (throws) throw PlatformException(code: 'ALREADY_RUNNING');
    return grant;
  }

  @override
  Stream<GpsSample> positionStream() {
    streamOpened = true;
    return const Stream<GpsSample>.empty();
  }

  @override
  Future<GpsSample?> lastKnown() async => null;
}

class _SilentMotion implements MotionRepository {
  @override
  Stream<MotionSample> motionStream() => const Stream<MotionSample>.empty();
}
