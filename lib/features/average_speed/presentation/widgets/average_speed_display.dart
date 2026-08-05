import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/formatters.dart';
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
      averageSpeedMpsProvider.select((mps) => Formatters.speed(mps, unit)),
    );
    final moving = ref.watch(
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
      // displayed". This is the OVERALL average: AverageSpeedCalculator accrues
      // time on every accepted delta, including while the car is stationary, so
      // the figure decays the longer you sit still. An unlabelled "AVG SPEED"
      // left a co-driver unable to tell which of the two they were reading,
      // which on a pace-keeping instrument is the difference between being on
      // time and being early.
      label: 'AVG (ALL)',
      onTap: () => ref.read(averageSpeedProvider.notifier).reset(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
          // The MOVING average rides under the overall one rather than taking a
          // sixth grid tile. Both are named on screen, which is what §8 asks
          // for; a co-driver who cannot tell which average they are reading is
          // the failure this guards against.
          //
          // Spelled "MOVING" with its unit, not "MOV". The abbreviation shipped
          // for about ten minutes and the first person to see it asked what it
          // meant, which is the whole failure §8 is warning about happening in
          // miniature. Four saved characters are not worth an unreadable
          // instrument.
          Text(
            'MOVING $moving ${unit.label}',
            style: TextStyle(
              color: colors.secondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
