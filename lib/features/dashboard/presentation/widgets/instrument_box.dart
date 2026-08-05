import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';

/// A labelled instrument tile — the building block of the cluster. Flat,
/// high-contrast, minimal border. No shadows/gradients (sunlight legibility).
///
/// The value area scales DOWN to fit the tile rather than overflowing. The
/// cluster is a fixed, non-scrolling panel, and the readouts are set in
/// `displaySmall` (72 px) — taller than a tile gets on a short landscape phone
/// once several are stacked. An overflow here doesn't just clip a pixel or two;
/// it strikes the value out with the debug banner and makes the instrument
/// unreadable mid-stage. Shrinking is always preferable to that.
///
/// `scaleDown` never scales UP, so tiles with room render exactly as before.
///
/// Because the tile handles the scaling, a [child] must shrink-wrap — use
/// `mainAxisSize: MainAxisSize.min` and no `Expanded`/`Flexible` inside it. A
/// flex child would demand infinite width from the [FittedBox] and assert.
class InstrumentBox extends StatelessWidget {
  const InstrumentBox({
    super.key,
    required this.label,
    required this.child,
    this.accent,
    this.onTap,
    this.onLongPress,
    // Tight vertical padding: on a short landscape phone several of these
    // stack, and every pixel of chrome comes straight out of the value.
    this.padding = const EdgeInsets.fromLTRB(14, 8, 14, 10),
  });

  final String label;
  final Widget child;
  final Color? accent;
  final VoidCallback? onTap;

  /// Destructive actions belong here, never on [onTap].
  ///
  /// A tile fills roughly 40 % of the cluster in landscape, so a tap target
  /// this large is one glove brush away on every stage. Anything that discards
  /// measured distance takes a deliberate hold.
  final VoidCallback? onLongPress;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = InstrumentColors.of(context);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accent ?? AppColors.divider, width: accent != null ? 2 : 1),
        ),
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: accent ?? colors.secondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 4),
            // Align expands to fill the tile's width (a bare FittedBox would
            // shrink-wrap, collapsing the tile around its digits); the
            // FittedBox inside then scales the value down only if the tile is
            // too short for it.
            Flexible(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
