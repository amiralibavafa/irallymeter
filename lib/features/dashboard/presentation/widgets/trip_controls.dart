import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../trip/domain/trip_state.dart';
import '../../../trip/presentation/providers/trip_providers.dart';

/// Glove-friendly manual correction pad: ±10 m / ±100 m for a target trip.
/// Big hit targets (>=56 px), high contrast, instant action.
class TripControls extends ConsumerWidget {
  const TripControls({super.key, this.counter = TripCounter.a});

  final TripCounter counter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(tripProvider.notifier);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final step in AppConstants.correctionSteps) ...[
          _CorrButton(
            label: '-$step',
            color: AppColors.danger,
            onTap: () => notifier.adjust(counter, -step.toDouble()),
          ),
        ],
        _ResetButton(onTap: () => notifier.resetTrip(counter), label: counter == TripCounter.a ? 'RST A' : 'RST B'),
        for (final step in AppConstants.correctionSteps) ...[
          _CorrButton(
            label: '+$step',
            color: AppColors.ok,
            onTap: () => notifier.adjust(counter, step.toDouble()),
          ),
        ],
      ],
    );
  }
}

class _CorrButton extends StatelessWidget {
  const _CorrButton({required this.label, required this.color, required this.onTap});
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Container(
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
              ),
              child: Text(
                label,
                style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ResetButton extends StatelessWidget {
  const _ResetButton({required this.onTap, required this.label});
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Container(
              height: 56,
              alignment: Alignment.center,
              child: Text(
                label,
                style: TextStyle(
                  // DAY token. RST A/B sits ON THE CLUSTER, which is the
                  // screen night mode exists for.
                  color: InstrumentColors.of(context).secondary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
