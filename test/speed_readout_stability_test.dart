// The speed readout must hold its size as the value crosses a digit boundary,
// AT THE COLUMN WIDTH THE CLUSTER ACTUALLY GIVES IT.
//
// This is C16 one widget over, and it was very nearly introduced by the fix for
// Amirali's father's second road-test note.
//
// He asked for Trip A bigger and the speed smaller. The obvious change is the
// flex split, and on its own that is a trap. `SpeedDisplay` derives its font
// size from available HEIGHT precisely so digit count cannot affect it, and its
// own comment says so:
//
//     "0" would render huge and "120" small, so the number would visibly jump
//     as the car accelerated. Height-derived, "8" and "188" are the same size.
//
// But the text still sits in a `FittedBox(scaleDown)`. Narrowing the column
// without lowering the height-derived size means three digits no longer FIT,
// so the FittedBox engages for "188" and not for "8" — and the size becomes
// digit-count dependent again through the back door. The doc comment would
// still describe the correct behaviour while the code had stopped implementing
// it, which is the exact failure theme of this whole audit.
//
// So these tests measure at the real landscape column width rather than in a
// generous box, because in a generous box nothing scales and they would pass
// against the defect.
//
// NOTE ON THE TEST FONT: flutter_test substitutes a font whose glyphs are all
// one width. That is fine here: what is under test is character COUNT driving
// the box, not glyph width.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/theme/app_theme.dart';
import 'package:irallymeter/core/utils/formatters.dart';
import 'package:irallymeter/features/dashboard/presentation/widgets/speed_display.dart';
import 'package:irallymeter/features/distance/domain/measurement_status.dart';
import 'package:irallymeter/features/distance/presentation/providers/distance_providers.dart';
import 'package:irallymeter/features/settings/presentation/providers/settings_providers.dart';

/// The landscape cluster is a Row of flex 3 (speed) and flex 6 (instruments)
/// with 10 px between. On a 900 px-wide phone in landscape that leaves the
/// speed panel roughly this wide. Deliberately on the SMALL side: the defect is
/// worst on the spare handset nobody reviews on.
const double _speedColumnWidth = 296;
const double _speedColumnHeight = 380;

void main() {
  group('SPEED · the readout holds its size across a digit boundary', () {
    testWidgets('01 · 8 and 188 km/h render at the same size', (tester) async {
      // The boundary a rally car crosses on any fast stage.
      final one = await _digitHeight(tester, 8 / 3.6);
      final three = await _digitHeight(tester, 188 / 3.6);

      expect(three, closeTo(one, 0.5),
          reason: 'the speed changed size as the car accelerated. The value '
              'sits in a FittedBox, so once three digits stop fitting the '
              'column the size becomes digit-count dependent again, which is '
              'the thing the height-derived sizing exists to prevent');
    });

    testWidgets('02 · every length in the range is the same size',
        (tester) async {
      // One boundary could be a coincidence of where this column happens to
      // sit. One, two and three digits must all land in the same place.
      final one = await _digitHeight(tester, 8 / 3.6);
      final two = await _digitHeight(tester, 88 / 3.6);
      final three = await _digitHeight(tester, 288 / 3.6);

      expect(two, closeTo(one, 0.5));
      expect(three, closeTo(one, 0.5),
          reason: 'a rally car passes through all three lengths on one stage');
    });

    testWidgets('02b · large-text accessibility does not bring it back',
        (tester) async {
      // THE CAP HAS TO KNOW ABOUT THE TEXT SCALER. Flutter applies
      // `MediaQuery.textScaler` to the Text AFTER the size is chosen, so
      // dividing the raw width by three reserves room for three UNSCALED
      // glyphs. At 1.5x accessibility scaling three digits then overflow, the
      // FittedBox engages for "188" and not for "8", and the collapse this cap
      // exists to prevent returns under a setting the OS fully supports.
      // Codex found it; the other tests all run at the default scale.
      final one = await _digitHeight(tester, 8 / 3.6, scale: 1.5);
      final three = await _digitHeight(tester, 188 / 3.6, scale: 1.5);

      expect(three, closeTo(one, 0.5),
          reason: 'with large text enabled the speed resized across 100 km/h '
              'again, which is the original defect wearing a different hat');
    });

    testWidgets('03 · the widest realistic value is not clipped',
        (tester) async {
      // Holding a constant size is worthless if it achieves it by cutting a
      // digit off. 288 km/h is past anything this app will see on a stage and
      // must still render whole.
      await _pump(tester, 288 / 3.6);
      expect(find.text('288'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

/// Rendered height of the speed digits in a box the size of the real cluster
/// column. `getRect` is used rather than `getSize` because it applies the
/// FittedBox transform, and the transform IS what is under test.
Future<double> _digitHeight(WidgetTester tester, double mps,
    {double scale = 1.0}) async {
  await _pump(tester, mps, scale: scale);
  final text = find.byType(Text).first;
  final rect = tester.getRect(text);
  await tester.pumpWidget(const SizedBox.shrink());
  return rect.height;
}

Future<void> _pump(WidgetTester tester, double mps, {double scale = 1.0}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        displaySpeedMpsProvider.overrideWith((ref) => mps),
        speedUnitProvider.overrideWith((ref) => SpeedUnit.kmh),
        measurementStatusProvider
            .overrideWith((ref) => MeasurementStatus.measured),
      ],
      child: MaterialApp(
        theme: AppTheme.build(DisplayMode.day),
        home: Scaffold(
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: Center(
            child: SizedBox(
              width: _speedColumnWidth,
              height: _speedColumnHeight,
              child: const Center(child: SpeedDisplay()),
            ),
          ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
