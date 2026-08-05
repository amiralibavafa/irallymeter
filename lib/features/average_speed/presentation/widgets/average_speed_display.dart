import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/stable_width_text.dart';
import '../../../dashboard/presentation/widgets/instrument_box.dart';
import '../../../settings/presentation/providers/settings_providers.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../distance/domain/measurement_status.dart';
import '../../../distance/presentation/providers/distance_providers.dart';
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
      movingAverageSpeedMpsProvider.select((mps) => Formatters.speed(mps, unit)),
    );
    final colors = InstrumentColors.of(context);
    // §5.1: average speed is distance / time, and the distance half may be
    // estimated — so it is an affected value like the trips and the odometer.
    final status = ref.watch(measurementStatusProvider);
    final avgColor = switch (status.state) {
      MeasurementState.measured => colors.primary,
      MeasurementState.reconciling => AppColors.info,
      MeasurementState.estimated =>
        status.isLowConfidence ? AppColors.danger : AppColors.warn,
    };

    return InstrumentBox(
      // SPEC-v2 §8 names two averages — moving (excluding stops) and overall
      // (including stops) — and requires the app to "make clear which one is
      // displayed". It does NOT require both on screen at once, and showing
      // both put two numbers and two unit strings in a tile this size, which
      // Saam called correctly as clutter.
      //
      // So ONE number, and the label says which. It is the MOVING average:
      // stationary time is excluded, so the figure answers "how fast am I
      // actually driving" and does not decay while parked at a control.
      //
      // The overall average is still computed and still one line away —
      // `averageSpeedMpsProvider` is untouched and `AverageSpeedCalculator`
      // keeps both denominators. Only the rendering changed, so restoring it is
      // a display decision, not a rebuild.
      label: 'AVG (MOVING)',
      // Long-press for the same reason as the trip tiles: this is a
      // destructive action on a target that fills a large part of the cluster.
      onLongPress: () => ref.read(averageSpeedProvider.notifier).reset(),
      child: Row(
        // Shrink-wrap: InstrumentBox scales the value area to fit the tile.
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          // Same tile mechanism as the trip readouts: the FittedBox scales on
          // the child's own size, so 9 renders larger than 100. Three digits
          // covers every average this readout will show.
          StableWidthText(
            value: value.toString(),
            template: '000',
            style: Theme.of(context)
                .textTheme
                .displaySmall
                ?.copyWith(color: avgColor),
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
