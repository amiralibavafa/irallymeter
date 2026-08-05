import 'package:flutter/material.dart';

/// A readout whose width is set by [template] rather than by its own value, so
/// the digits keep their size and the decimal point keeps its place.
///
/// WHY THIS EXISTS, measured rather than assumed. The cluster readouts sit
/// inside `InstrumentBox`, which wraps them in `FittedBox(fit:
/// BoxFit.scaleDown)`. A `FittedBox` scales on the CHILD'S OWN SIZE, so the
/// scale factor depends on how many characters the value happens to have.
/// Rendering `displaySmall` into a 360 x 110 tile:
///
///     "9.99"    69.0 px tall
///     "99.99"   59.5 px tall
///     "100.00"  50.5 px tall
///
/// Trip A crossing 100 km therefore shrinks the number a co-driver is reading
/// aloud by about 15 % in a single step, and it grows back again the next time
/// the value gets shorter. On a wide tile the effect nearly vanishes (72.0 to
/// 71.9 at 500 px), which is why it never showed up in a screenshot review:
/// it depends on the tile being tight, and the tile is tightest on the small
/// phones a crew is most likely to be using as a spare.
///
/// The speed display solves the same problem a different way — it derives its
/// font size from the available HEIGHT so the digit count cannot reach it. That
/// works there because the value is one to three characters and never runs out
/// of width. A trip readout is four to six characters plus a unit suffix, so
/// width is the binding constraint and only reserving it will do.
///
/// Deliberately NOT done with zero padding (`007.35`). Padding would fix the
/// width just as well and is the classic mechanical-tripmeter look, but it is a
/// visual decision rather than a correctness one, and this way the number reads
/// exactly as it does today.
class StableWidthText extends StatelessWidget {
  const StableWidthText({
    super.key,
    required this.value,
    required this.template,
    this.style,
  });

  /// The value actually shown.
  final String value;

  /// The widest string this readout is expected to have to display. A value
  /// wider than the template still renders correctly in full — the box simply
  /// resumes growing, which is the behaviour everything had before.
  final String template;

  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Stack(
        // Right-aligned: this is what holds the decimal point still. Aligning
        // left would keep the width constant but let the point drift.
        alignment: Alignment.centerRight,
        children: [
          // Invisible but still laid out, so it is what sets the Stack's width.
          // `SizedBox` with a hard number would not survive a text-scale or
          // font change; this tracks whatever the style actually renders.
          Visibility(
            visible: false,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: Text(template, style: style),
          ),
          Text(value, style: style),
        ],
      );
}
