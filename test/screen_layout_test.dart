// LAYOUT at every orientation the app allows, for the screens Amirali's
// dashboard_layout_test does not cover.
//
// Written because Saam had to catch three layout defects by screenshot in one
// session, which means checking by eye was not working. `main.dart` allows
// landscapeLeft, landscapeRight and portraitUp, so "it looked fine" has to mean
// all three plus the smallest phone we support, and that is a test's job.
//
// TWO DIFFERENT FAILURES ARE CHECKED HERE, because one assertion cannot see
// both:
//
//   * OVERFLOW — a RenderFlex that does not fit. Flutter raises an exception,
//     so `takeException()` catches it. This is what the stage-timer tests do.
//
//   * OVERLAP — two `Positioned` overlays sitting on top of each other. This
//     raises NOTHING. It renders happily and silently hides content, which is
//     exactly how the offline-map banner ended up under the compass and then
//     under the buttons. Only comparing rectangles finds it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/di/providers.dart';
import 'package:irallymeter/core/storage/storage_service.dart';
import 'package:irallymeter/core/theme/app_theme.dart';
import 'package:irallymeter/features/stage_timer/presentation/stage_timer_screen.dart';
import 'package:irallymeter/features/stage_timer/presentation/providers/stage_timer_providers.dart';
import 'package:irallymeter/features/stage_timer/domain/stage_timer_state.dart';

void main() {
  late StorageService storage;
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('irallymeter_screens');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    storage = await StorageService.init();
  });

  tearDownAll(() async => tempDir.delete(recursive: true));

  // The three orientations main.dart permits, plus the tight case. Same
  // Pixel-class logical sizes dashboard_layout_test already uses, so the two
  // files agree on what "a real device" means.
  const landscape = Size(1038.5, 465.5);
  const portrait = Size(465.5, 1038.5);
  const smallLandscape = Size(800, 360);
  const smallPortrait = Size(360, 800);

  const sizes = <String, Size>{
    'landscape': landscape,
    'portrait': portrait,
    'small landscape': smallLandscape,
    'small portrait': smallPortrait,
  };

  group('STAGE TIMER · layout at every allowed orientation', () {
    // landscapeLeft and landscapeRight produce the SAME logical size, so one
    // landscape case covers both for layout purposes. What differs between them
    // on a real device is the safe-area inset, which Scaffold+SafeArea handles
    // and which a test surface does not model — noted so nobody reads this as
    // covering more than it does.
    for (final entry in sizes.entries) {
      testWidgets('stopwatch mode fits: ${entry.key}', (tester) async {
        await _pumpTimer(tester, storage, entry.value, TimerMode.stopwatch);
        await _expectNoOverflow(tester, entry.key);
      });

      testWidgets('countdown mode fits: ${entry.key}', (tester) async {
        // Countdown is the taller case: it adds the TARGET line and a row of
        // four adjust buttons that stopwatch mode does not have. That row is
        // new, so this is the case most likely to break.
        await _pumpTimer(tester, storage, entry.value, TimerMode.countdown);
        await _expectNoOverflow(tester, entry.key);
      });
    }

    testWidgets('the four adjust buttons stay glove-sized', (tester) async {
      await _pumpTimer(tester, storage, smallPortrait, TimerMode.countdown);

      for (final label in ['-1:00', '-0:10', '+0:10', '+1:00']) {
        final rect = tester.getRect(find.text(label).first);
        expect(rect.height, greaterThanOrEqualTo(20),
            reason: '$label collapsed on the narrowest phone we support');
      }
      await _unmount(tester);
    });

    testWidgets('TARGET and the adjust row do not overlap the controls',
        (tester) async {
      // The overlap class of bug, on the screen where a new row was inserted
      // above existing buttons.
      await _pumpTimer(tester, storage, smallPortrait, TimerMode.countdown);

      final adjust = tester.getRect(find.text('+1:00'));
      final start = tester.getRect(find.text('START'));

      expect(adjust.bottom, lessThanOrEqualTo(start.top),
          reason: 'the countdown adjust row is sitting on top of START — a '
              'mis-tap there starts a stage instead of setting its length');
      await _unmount(tester);
    });
  });
}

Future<void> _pumpTimer(
  WidgetTester tester,
  StorageService storage,
  Size logicalSize,
  TimerMode mode,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logicalSize;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [storageProvider.overrideWithValue(storage)],
      child: MaterialApp(
        theme: AppTheme.build(DisplayMode.day),
        home: const StageTimerScreen(),
      ),
    ),
  );
  await tester.pump();

  if (mode == TimerMode.countdown) {
    final ctx = tester.element(find.byType(StageTimerScreen));
    ProviderScope.containerOf(ctx)
        .read(stageTimerProvider.notifier)
        .setMode(TimerMode.countdown);
    await tester.pump();
  }
}

/// The stage timer runs a 100 ms ticker, so the tree must be unmounted before
/// the test ends or the pending-timer check trips.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Future<void> _expectNoOverflow(WidgetTester tester, String label) async {
  final error = tester.takeException();
  await _unmount(tester);
  expect(error, isNull,
      reason: 'the stage timer overflowed at $label — a countdown a crew '
          'cannot fully read is worse than no countdown');
}
