import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/formatters.dart';
import '../../../distance/presentation/providers/distance_providers.dart';
import '../../../distance/domain/measurement_status.dart';
import '../../../../core/theme/app_colors.dart';
import 'measurement_badge.dart';
import '../../../settings/presentation/providers/settings_providers.dart';

/// The hero readout. Rebuilds ONLY when the integer speed value changes, not
/// on every raw GPS tick — `displaySpeedMpsProvider` is selected and we convert
/// to an int, so sub-unit jitter never triggers a repaint.
///
/// Reads the distance engine's speed rather than GPS directly, so entering a
/// tunnel switches the readout to the sensor estimate instead of freezing it at
/// the last fix's value.
class SpeedDisplay extends ConsumerWidget {
  const SpeedDisplay({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unit = ref.watch(speedUnitProvider);
    // Select to the displayed integer so rebuilds are quantised to whole units.
    final value = ref.watch(
      displaySpeedMpsProvider.select((mps) => Formatters.speed(mps, unit)),
    );
    final colors = InstrumentColors.of(context);
    final status = ref.watch(measurementStatusProvider);

    // SPEC-v2 §5.1: an estimated figure must not look like a measured one.
    // "Hide the correction. Never hide the estimation."
    final digitColor = switch (status.state) {
      MeasurementState.measured => colors.primary,
      MeasurementState.reconciling => AppColors.info,
      MeasurementState.estimated =>
        status.isLowConfidence ? AppColors.danger : AppColors.warn,
    };

    // THE PRIMARY NUMBER, SIZED TO THE SPACE IT IS GIVEN.
    //
    // This used to be a fixed 180 px (`displayLarge`) inside
    // `FittedBox(fit: BoxFit.scaleDown)`, and scaleDown only ever SHRINKS — it
    // never enlarges. So on the landscape cluster the digit filled about 40 %
    // of its panel and the rest was dead black, on the one number a co-driver
    // reads at arm's length on a vibrating mount in daylight.
    //
    // Derived from the available HEIGHT rather than a `FittedBox` on the text,
    // because fitting the text itself makes the size depend on the digit COUNT:
    // "0" would render huge and "120" small, so the number would visibly jump
    // as the car accelerated. Height-derived, "8" and "188" are the same size.
    return LayoutBuilder(
      builder: (context, c) {
        // Leave room for the badge and the unit label beneath.
        final reserved = (compact ? 34.0 : 54.0) + (status.badge != null ? 26.0 : 0.0);
        final available = (c.maxHeight - reserved).clamp(48.0, double.infinity);
        final byHeight = c.maxHeight.isFinite
            ? (available * 0.82).clamp(56.0, compact ? 120.0 : 320.0)
            : (compact ? 72.0 : 180.0);

        // WIDTH MATTERS TOO, and leaving it out was very nearly a shipped
        // defect. Height alone is what keeps the size independent of digit
        // COUNT, which is the property the comment above describes. But the
        // text still sits in the `FittedBox` below, so the instant the widest
        // value stops FITTING the column, that FittedBox engages for "188" and
        // not for "8" and the size becomes digit-count dependent again through
        // the back door.
        //
        // It was measured, not reasoned: after the cluster was rebalanced to
        // give Trip A more room, "8" rendered 267 px tall and "188" rendered
        // 98.9 px in the same panel. That is a 63 % collapse as the car
        // accelerates, considerably worse than the 25 % trip-readout swing C16
        // was raised for.
        //
        // Three characters is the widest this instrument ever shows, and a
        // full em per character is the worst-case advance for any font. So
        // capping at maxWidth / 3 guarantees the widest value fits without
        // scaling, at any column width, on any font. The FittedBox stays as the
        // guard it was always meant to be rather than as a participant in
        // normal sizing.
        const maxDigits = 3;
        final byWidth =
            c.maxWidth.isFinite ? c.maxWidth / maxDigits : double.infinity;
        final size = math.min(byHeight, byWidth);

        return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value.toString(),
            style: (compact
                    ? Theme.of(context).textTheme.displaySmall
                    : Theme.of(context).textTheme.displayLarge)
                ?.copyWith(color: digitColor, fontSize: size, height: 1.0),
          ),
        ),
        if (status.badge != null) MeasurementBadge(status: status),
        GestureDetector(
          onTap: () => ref.read(settingsProvider.notifier).toggleSpeedUnit(),
          child: Text(
            unit.label,
            style: TextStyle(
              color: colors.accent,
              fontSize: compact ? 16 : 26,
              fontWeight: FontWeight.w700,
              letterSpacing: 3,
            ),
          ),
        ),
      ],
        );
      },
    );
  }
}
