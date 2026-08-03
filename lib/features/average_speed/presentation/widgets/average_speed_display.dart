import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/formatters.dart';
import '../../../dashboard/presentation/widgets/instrument_box.dart';
import '../../../settings/presentation/providers/settings_providers.dart';
import '../providers/average_speed_providers.dart';

/// Average-speed instrument tile. Mirrors a rally trip meter's average readout:
/// total distance ÷ travel time, in the user's chosen unit. Tap to reset the
/// average for a fresh leg (does not affect Trip A/B or the odometer).
class AverageSpeedDisplay extends ConsumerWidget {
  const AverageSpeedDisplay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unit = ref.watch(speedUnitProvider);
    // Quantise rebuilds to the displayed integer, like the hero speedometer.
    final value = ref.watch(
      averageSpeedMpsProvider.select((mps) => Formatters.speed(mps, unit)),
    );
    final colors = InstrumentColors.of(context);

    return InstrumentBox(
      label: 'AVG SPEED',
      onTap: () => ref.read(averageSpeedProvider.notifier).reset(),
      child: Row(
        // Shrink-wrap: InstrumentBox scales the value area to fit the tile.
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            value.toString(),
            style: Theme.of(context)
                .textTheme
                .displaySmall
                ?.copyWith(color: colors.primary),
          ),
          const SizedBox(width: 6),
          Text(
            unit.label,
            style: TextStyle(
              color: colors.secondary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
