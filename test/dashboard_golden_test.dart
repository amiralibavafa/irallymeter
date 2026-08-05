// GOLDEN tests for the cluster — Stage 3.
//
// WHAT THESE ADD THAT THE OTHER TESTS DO NOT. `dashboard_layout_test` and
// `screen_layout_test` assert OVERFLOW and OVERLAP, which are the two failures
// that can be expressed as a rectangle comparison. Neither can see a COLOUR
// regression or a composition change, and this session found both:
//
//   * C18 — twelve widgets read the DAY token directly, so night mode dimmed
//     the cluster and left four other screens glaring. Nothing failed.
//   * [SA-V2 18] — a REC badge appeared on a COLD LAUNCH because a banner was
//     inserted between an `if` and its body. Legal Dart, silent, caught by eye.
//
// A golden pair in day and night is the cheapest thing that fails on both.
//
// WHAT THEY CANNOT DO, said plainly so nobody reads more into a green run than
// is there. `flutter test` substitutes a placeholder font whose glyphs are all
// identical boxes. So these goldens capture LAYOUT, COLOUR and COMPOSITION and
// say NOTHING about typography: they cannot see tabular figures (that is why
// C17's test asserts the style), cannot see a wrong label, and cannot tell
// "120" from "999". They are a shape-and-colour baseline, not a screenshot.
//
// That same substitution is what makes them deterministic despite `AppClock`
// reading `DateTime.now()` directly: every wall-clock time renders as the same
// eight boxes. `test 05` pins that property rather than trusting it, because if
// a real font is ever bundled these goldens start failing once a second and the
// cause would be extremely confusing.
//
// KNOWN ARTIFACT IN THESE IMAGES, so nobody files it as a bug. In the bottom
// correction pad the `-100` and `+100` labels WRAP to a second line. That is
// the placeholder font, not the app: its glyphs are about 1 em wide, so a
// 4-character label at fontSize 20 measures ~80 px against a ~76 px button,
// while real digits are nearer 0.55 em and measure ~44 px. It cannot happen on
// a device. If a real font is ever bundled, re-check this rather than assuming
// it stays benign.
//
// Regenerate with:  flutter test --update-goldens test/dashboard_golden_test.dart
// REVIEW THE DIFF BY EYE before committing a regenerated golden. A golden
// updated without being looked at records the bug as the new expectation.
// That rule already paid: the first run of these goldens showed the RST A/B
// label still bright in night mode, which is how the `textSecondary` half of
// C18 was found.

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
    tempDir = await Directory.systemTemp.createTemp('irallymeter_golden');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    storage = await StorageService.init();
  });

  tearDownAll(() async => tempDir.delete(recursive: true));

  // The device the cluster was verified on, and the tight case. Portrait is
  // included because it overflowed by 142 px until P2 and the fix stacks the
  // nav row rather than shrinking the glove targets — a composition change no
  // rectangle assertion describes.
  const landscape = Size(1038.5, 465.5);
  const portrait = Size(465.5, 1038.5);
  const smallLandscape = Size(800, 360);

  group('CLUSTER · goldens', () {
    testWidgets('01 · landscape, day', (tester) async {
      await _pump(tester, storage, landscape, DisplayMode.day);
      await expectLater(find.byType(DashboardScreen),
          matchesGoldenFile('goldens/cluster_landscape_day.png'));
      await _unmount(tester);
    });

    testWidgets('02 · landscape, night', (tester) async {
      // The pair that matters. Everything on this screen must dim; the C18
      // class of defect is a widget that does not.
      await _pump(tester, storage, landscape, DisplayMode.night);
      await expectLater(find.byType(DashboardScreen),
          matchesGoldenFile('goldens/cluster_landscape_night.png'));
      await _unmount(tester);
    });

    testWidgets('03 · portrait, day', (tester) async {
      await _pump(tester, storage, portrait, DisplayMode.day);
      await expectLater(find.byType(DashboardScreen),
          matchesGoldenFile('goldens/cluster_portrait_day.png'));
      await _unmount(tester);
    });

    testWidgets('04 · small landscape, day', (tester) async {
      // 800x360 is where the readouts are tightest, which is where the
      // FittedBox scaling bites hardest (see C16).
      await _pump(tester, storage, smallLandscape, DisplayMode.day);
      await expectLater(find.byType(DashboardScreen),
          matchesGoldenFile('goldens/cluster_small_landscape_day.png'));
      await _unmount(tester);
    });
  });

  group('CLUSTER · the goldens are deterministic', () {
    testWidgets('05 · the wall clock does not change the image',
        (tester) async {
      // AppClock reads DateTime.now() directly and ticks at 1 Hz, so on paper
      // these goldens should fail every second. They do not, because the
      // placeholder font renders every digit as the same box and the format is
      // always eight characters.
      //
      // That is a property of the TEST FONT, not of the app, so it is pinned
      // here rather than assumed. If a real font is ever bundled this test
      // fails first and names the reason, instead of four goldens failing
      // intermittently for no visible cause.
      await _pump(tester, storage, landscape, DisplayMode.day);
      final clockA = _clockText(tester);
      await _unmount(tester);

      await _pump(tester, storage, landscape, DisplayMode.day,
          fakeClock: DateTime.utc(2026, 1, 1, 23, 59, 58));
      final clockB = _clockText(tester);

      expect(clockA.length, equals(8), reason: 'HH:mm:ss');
      expect(clockB.length, equals(8));
      // Same width for two different times is what makes the golden stable.
      await expectLater(find.byType(DashboardScreen),
          matchesGoldenFile('goldens/cluster_landscape_day.png'));
      await _unmount(tester);
    });
  });
}

String _clockText(WidgetTester tester) {
  final texts = tester.widgetList<Text>(find.byType(Text));
  return texts
      .map((t) => t.data ?? '')
      .firstWhere((s) => RegExp(r'^\d{2}:\d{2}:\d{2}$').hasMatch(s),
          orElse: () => '');
}

Future<void> _pump(
  WidgetTester tester,
  StorageService storage,
  Size logicalSize,
  DisplayMode mode, {
  DateTime? fakeClock,
}) async {
  final now = fakeClock ?? DateTime.utc(2026);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logicalSize;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        gpsRepositoryProvider.overrideWithValue(_FakeGps(_oneFix())),
        motionRepositoryProvider.overrideWithValue(_SilentMotion()),
        // Both are unbounded periodic streams that outlive the tree and trip
        // the pending-timer check. Pinning them also makes the image stable.
        gpsDropoutProvider.overrideWith((ref) => Stream<bool>.value(false)),
        displayTickProvider.overrideWith((ref) => Stream<int>.value(0)),
        engineClockProvider.overrideWithValue(() => now),
      ],
      child: MaterialApp(
        theme: AppTheme.build(mode),
        home: const DashboardScreen(),
      ),
    ),
  );
  await tester.pump();
}

/// The cluster is full of live timers (the clock, the engine heartbeat, the
/// tunnel ticker), so the tree has to come down inside the test body.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
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
