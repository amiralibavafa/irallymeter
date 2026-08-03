import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/formatters.dart';
import '../../../distance/presentation/providers/distance_providers.dart';
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
                ?.copyWith(color: colors.primary),
          ),
        ),
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
  }
}
