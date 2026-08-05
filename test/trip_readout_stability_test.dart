// C16 — the trip readout physically resized as the value crossed a digit.
//
// `InstrumentBox` wraps its value area in `FittedBox(fit: BoxFit.scaleDown)`,
// and a FittedBox scales on the child's OWN size. So the scale factor depended
// on how many characters the number happened to have, and Trip A crossing
// 100.00 km made itself smaller.
//
// Measured before the fix, `displaySmall` in a 360 x 110 tile:
//
//     "9.99"    69.0 px tall
//     "99.99"   59.5 px tall
//     "100.00"  50.5 px tall
//
// That is a ~27 % swing across the range on the one number a co-driver reads
// aloud, and it swings back the other way when the value shortens again. It is
// also why nobody caught it by eye: at a 500 px tile the same values render
// 72.0 and 71.9, so it is invisible on a big screen and worst on the small
// phone a crew carries as a spare.
//
// These tests assert the property directly — the same value at a different
// LENGTH must render at the same SIZE — rather than asserting a pixel number,
// which would only pin today's font metrics.
//
// NOTE ON THE TEST FONT: flutter_test substitutes a font whose glyphs are all
// one width. That makes it useless for proving the tabular-figures work (C17
// asserts the STYLE for exactly this reason) but perfectly good here, because
// what is under test is character COUNT driving the box, not glyph width.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/theme/app_theme.dart';
import 'package:irallymeter/features/dashboard/presentation/widgets/trip_panel.dart';
import 'package:irallymeter/features/distance/domain/measurement_status.dart';
import 'package:irallymeter/features/distance/presentation/providers/distance_providers.dart';
import 'package:irallymeter/features/settings/presentation/providers/settings_providers.dart';
import 'package:irallymeter/features/trip/domain/trip_state.dart';
import 'package:irallymeter/features/trip/presentation/providers/trip_providers.dart';

void main() {
  group('C16 · the trip readout holds its size across a digit boundary', () {
    testWidgets('01 · 9.99 and 100.00 render at the same size',
        (tester) async {
      // THE REGRESSION, at the boundary a rally leg actually crosses.
      final small = await _render(tester, 9990); // 9.99 km
      final large = await _render(tester, 100000); // 100.00 km

      expect(large.height, closeTo(small.height, 0.5),
          reason: 'crossing 100 km shrank the number the co-driver reads '
              'aloud. The value area is scaled to fit by a FittedBox, so an '
              'extra character makes the whole readout smaller');
    });

    testWidgets('02 · every step across the range is the same size',
        (tester) async {
      // One boundary could be a coincidence of where the tile happens to sit.
      // 4, 5 and 6 characters must all land in the same place.
      final four = await _render(tester, 9990); // 9.99
      final five = await _render(tester, 99990); // 99.99
      final six = await _render(tester, 999990); // 999.99

      expect(five.height, closeTo(four.height, 0.5));
      expect(six.height, closeTo(four.height, 0.5),
          reason: 'the readout must be the same size at every length inside '
              'the range the template reserves');
    });

    testWidgets('03 · the decimal point does not move', (tester) async {
      // The width being constant is not enough on its own. A left-aligned
      // value in a fixed box holds its width and still slides the point
      // sideways, which is the thing a co-driver tracks between glances.
      final short = await _pointX(tester, 9990); // 9.99
      final long = await _pointX(tester, 100000); // 100.00

      expect(long, closeTo(short, 0.5),
          reason: 'the digits are right-aligned in the reserved box for '
              'exactly this reason');
    });

    testWidgets('04 · a value wider than the template still renders in full',
        (tester) async {
      // The template reserves a width, it must not CLIP. Above it the readout
      // simply resumes growing, which is what everything did before.
      await _pump(tester, 1234560); // 1234.56 km
      expect(find.text('1234.56'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

/// The rendered rect of the value text, at a tile size small enough that the
/// FittedBox is actually engaged. On a wide tile nothing scales and the test
/// would pass against the defect.
Future<Size> _render(WidgetTester tester, double meters) async {
  await _pump(tester, meters);
  final r = tester.getRect(find.text(_expected(meters)));
  await tester.pumpWidget(const SizedBox.shrink());
  return Size(r.width, r.height);
}

/// Where the decimal point sits, in global coordinates.
Future<double> _pointX(WidgetTester tester, double meters) async {
  await _pump(tester, meters);
  final r = tester.getRect(find.text(_expected(meters)));
  final text = _expected(meters);
  // The test font is monospaced, so the point's offset is its index times the
  // per-character width. Measured from the RIGHT edge, which is the edge the
  // readout is anchored to.
  final charsAfterPoint = text.length - text.indexOf('.');
  final perChar = r.width / text.length;
  final x = r.right - charsAfterPoint * perChar;
  await tester.pumpWidget(const SizedBox.shrink());
  return x;
}

String _expected(double meters) => (meters / 1000).toStringAsFixed(2);

Future<void> _pump(WidgetTester tester, double meters) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1038.5, 465.5);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripAProvider.overrideWithValue(meters),
        isMetricProvider.overrideWithValue(true),
        measurementStatusProvider.overrideWithValue(const MeasurementStatus(
          state: MeasurementState.measured,
          confidence: EstimationConfidence.normal,
          estimatingFor: Duration.zero,
        )),
      ],
      child: MaterialApp(
        theme: AppTheme.build(DisplayMode.day),
        home: const Scaffold(
          body: Center(
            // A tight tile: this is where the scaling bites, and it is the
            // geometry of a small phone in landscape.
            child: SizedBox(
              width: 360,
              height: 110,
              child: TripReadout(counter: TripCounter.a),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
