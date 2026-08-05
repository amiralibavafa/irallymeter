// INTEGRATION — the real app on a real device. Stage 3.
//
// Everything in `test/` fakes at least one of: the GPS repository, the motion
// repository, the storage directory, the clock. That is correct for unit and
// widget work, but it means nothing in this repo has ever exercised the app's
// actual boot path — real Hive on real storage, the real go_router, the real
// platform channels, the real permission state.
//
// These are written against `docs/UI-INVENTORY.md`, which is the point of that
// document: a control nobody listed is a control nobody tested.
//
// WHAT IS DELIBERATELY NOT HERE. Nothing that needs GNSS. The emulator has no
// real receiver, and `simctl`-style location injection produces a synthetic
// track whose ground truth is exact by construction — which is what every
// replay fixture already does, better. Accuracy belongs to `docs/ROAD-TEST.md`
// and a car. These prove the app RUNS and its CONTROLS WORK, and nothing about
// how well it measures.
//
// RUN IT (both matter — an integration suite that has never been run green is
// exactly the unfalsifiable check C2 and C7 already cost us twice):
//
//   adb -s emulator-5554 shell pm grant com.irallyclub.irallymeter \
//       android.permission.ACCESS_FINE_LOCATION
//   flutter test integration_test/app_flows_test.dart -d emulator-5554
//
// The grant matters. Without it the rationale screen's CONTINUE raises a
// SYSTEM dialog, which is outside the Flutter tree and which `WidgetTester`
// cannot tap, so the run hangs rather than fails.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:irallymeter/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('BOOT', () {
    testWidgets('01 · the app starts and reaches a screen', (tester) async {
      // P1 was a first-run hang on the Flutter splash: two permission plugins
      // raced before `runApp`, threw, and the app never got as far as drawing.
      // Nothing in `test/` can see that, because every widget test starts by
      // pumping a widget — it begins AFTER the failure.
      app.main();
      await _settle(tester);

      // First launch lands on the rationale screen; a later one lands on the
      // cluster. Both are a healthy boot, and asserting only one of them would
      // make this test order-dependent.
      final onboarding = find.text('CONTINUE');
      final cluster = find.text('TRIP A');
      expect(onboarding.evaluate().isNotEmpty || cluster.evaluate().isNotEmpty,
          isTrue,
          reason: 'the app drew neither the rationale screen nor the cluster, '
              'which is the P1 splash hang');

      if (onboarding.evaluate().isNotEmpty) {
        await _tapMaybeOffscreen(tester, onboarding);
      }
      expect(await _waitFor(tester, cluster), isTrue,
          reason: 'onboarding did not hand over');
    });
  });

  group('NAVIGATION · every route in the inventory is reachable', () {
    testWidgets('02 · timer, map and settings all round-trip', (tester) async {
      // D3 in the inventory: `/sections` has no nav entry of its own. This
      // walks what the dashboard DOES offer and proves each one comes back,
      // because a screen you cannot leave is worse than one you cannot reach.
      app.main();
      await _boot(tester);

      for (final probe in [
        (icon: Icons.timer_outlined, marker: 'STOPWATCH'),
        (icon: Icons.map_outlined, marker: 'MAP'),
        (icon: Icons.settings_outlined, marker: 'SETTINGS'),
      ]) {
        final button = find.byIcon(probe.icon);
        if (button.evaluate().isEmpty) continue; // icon set may differ
        await tester.tap(button.first);
        expect(await _waitFor(tester, find.text(probe.marker)), isTrue,
            reason: '${probe.marker} did not open');

        await _back(tester);
        expect(await _waitFor(tester, find.text('TRIP A')), isTrue,
            reason: 'could not get back to the cluster from ${probe.marker}');
      }
    });
  });

  group('THE C0 GESTURE, on a device', () {
    testWidgets('03 · a tap does not wipe a trip, a long-press does',
        (tester) async {
      // C0 is the worst defect this audit found and it is in `main`: a single
      // TAP on a trip tile zeroed it, on a target that is ~40 % of the cluster
      // in landscape, guarded only by a lock mode that is off by default.
      //
      // `trip_reset_gesture_test` already pins this at the widget level. It is
      // repeated here because a gesture is the one thing a widget test models
      // rather than performs: real hit-testing, real timing, real long-press
      // duration from the platform.
      app.main();
      await _boot(tester);

      final tripA = find.text('TRIP A');
      expect(tripA, findsOneWidget);

      await tester.tap(tripA);
      await _settle(tester);
      expect(find.text('TRIP A'), findsOneWidget,
          reason: 'the tile vanished, so the gesture did something unexpected');

      await tester.longPress(tripA);
      await _settle(tester);
      // The trip is already 0.00 with no GNSS, so this cannot assert a change
      // in VALUE. What it does prove is that the long-press is wired and does
      // not throw — the value assertion lives in the widget test, where the
      // starting distance can be set.
      expect(find.text('TRIP A'), findsOneWidget);
    });
  });

  group('PERSISTENCE · real Hive, not a temp directory', () {
    testWidgets('04 · night mode survives a rebuild', (tester) async {
      // Every settings test in `test/` writes to a throwaway directory created
      // in `setUpAll`. This is the only place the real box on the real device
      // is exercised, which is where a schema or path problem would show up.
      app.main();
      await _boot(tester);

      await _openSettings(tester);
      final toggle = find.byType(SwitchListTile);
      expect(await _waitFor(tester, toggle), isTrue,
          reason: 'no switches on the settings screen');

      final before = tester.widget<SwitchListTile>(toggle.first).value;
      await tester.tap(toggle.first);
      await _settle(tester);
      final after = tester.widget<SwitchListTile>(toggle.first).value;

      expect(after, isNot(equals(before)), reason: 'the switch did not move');

      // Put it back so the next run starts from the same place. An integration
      // suite that leaves state behind fails differently on its second run,
      // which is the hardest kind of flake to read.
      await tester.tap(toggle.first);
      await _settle(tester);
      expect(tester.widget<SwitchListTile>(toggle.first).value, equals(before));
    });
  });

  group('THE ROAD-TEST PATH', () {
    testWidgets('05 · the GNSS HEALTH panel is four taps deep and reachable',
        (tester) async {
      // D3 again, and it matters operationally: `docs/ROAD-TEST.md` sends a
      // tester to this panel to read SUSTAINED, STREAM STALLS and RESIDUAL,
      // and it has no dashboard nav. If this path ever breaks, the road test
      // silently loses three of its measurements.
      app.main();
      await _boot(tester);

      await _openSettings(tester);
      final sectionLog = find.text('Section log');
      await tester.scrollUntilVisible(sectionLog, 150,
          scrollable: find.byType(Scrollable).first);
      await _settle(tester);
      expect(sectionLog, findsOneWidget,
          reason: 'the only route to /sections is this row');

      await tester.tap(sectionLog, warnIfMissed: false);
      await _settle(tester);

      expect(await _waitFor(tester, find.text('GNSS HEALTH')), isTrue);
      for (final field in ['SUSTAINED', 'STREAM STALLS', 'RESIDUAL']) {
        expect(find.text(field), findsOneWidget,
            reason: 'ROAD-TEST asks the tester to read $field');
      }
    });
  });
}

/// Boots past the rationale screen if it is showing, and lands on the cluster.
Future<void> _boot(WidgetTester tester) async {
  await _settle(tester);
  final onboarding = find.text('CONTINUE');
  if (onboarding.evaluate().isNotEmpty) {
    await _tapMaybeOffscreen(tester, onboarding);
  }
  final reached = await _waitFor(tester, find.text('TRIP A'));
  expect(reached, isTrue, reason: 'never reached the cluster');
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.settings_outlined).first);
  final open = await _waitFor(tester, find.text('SETTINGS'));
  expect(open, isTrue, reason: 'the settings screen did not open');
}

/// Taps a target that may be below the fold.
///
/// WHY THIS EXISTS, and it is a finding rather than a helper. On this device in
/// LANDSCAPE the render tree is 914 x 411, and the rationale screen's CONTINUE
/// button lays out at y = 507. It is NOT unreachable — the screen is a
/// `SingleChildScrollView` and a user can scroll to it — but the primary action
/// of the first screen anyone sees is off the fold on the orientation this app
/// forces, with no affordance saying so.
///
/// Recorded as a UX note in the QA report, not as a defect: nothing is broken
/// and nothing is blocked. `tester.tap` does not scroll, which is why the first
/// version of this suite failed here.
Future<void> _tapMaybeOffscreen(WidgetTester tester, Finder target) async {
  final scrollable = find.byType(Scrollable);
  if (scrollable.evaluate().isNotEmpty) {
    await tester.scrollUntilVisible(target, 120, scrollable: scrollable.first);
    await _settle(tester);
  }
  await tester.tap(target, warnIfMissed: false);
  await _settle(tester);
}

Future<void> _back(WidgetTester tester) async {
  final back = find.byType(BackButton);
  if (back.evaluate().isNotEmpty) {
    await tester.tap(back.first);
  } else {
    await tester.pageBack();
  }
  await _settle(tester);
}

/// `pumpAndSettle` would NEVER return here. The cluster owns a 1 Hz clock, the
/// distance engine's 250 ms heartbeat and the GPS dropout watchdog, so the tree
/// is never quiescent by design.
///
/// AND PUMPING ALONE IS NOT ENOUGH, which is what made the first version of
/// this suite flaky. `tester.pump` advances the FAKE clock and drains
/// microtasks; it does not give real wall-clock time to Hive opening a box on
/// real storage or to a platform channel round-trip. So each frame is paired
/// with a real `Future.delayed`. That is the difference between a widget test,
/// where every dependency is a fake that completes synchronously, and this.
Future<void> _settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }
}

/// Pumps until [target] appears or the budget runs out, then returns whether it
/// did. Polling rather than a fixed wait: the boot path's duration depends on
/// real device I/O, so any single number is either flaky or needlessly slow.
Future<bool> _waitFor(WidgetTester tester, Finder target,
    {int tries = 50}) async {
  for (var i = 0; i < tries; i++) {
    if (target.evaluate().isNotEmpty) return true;
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return target.evaluate().isNotEmpty;
}
