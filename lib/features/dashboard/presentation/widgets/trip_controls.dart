import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../average_speed/presentation/providers/average_speed_providers.dart';
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
        // ZERO EVERYTHING. Long-press, never tap — see [TripNotifier.resetAll].
        // The odometer is a lifetime total with no undo, and C0 was a plain tap
        // wiping a single trip. The label says HOLD so the gesture is
        // discoverable instead of hidden.
        _ResetButton(
          label: 'RST ALL\nHOLD',
          onLongPress: () {
            notifier.resetAll();
            // The average speed is the third accumulator on the cluster and is
            // what "speed" in the request can actually mean; the live
            // speedometer is a GPS reading and cannot be zeroed.
            ref.read(averageSpeedProvider.notifier).reset();
          },
        ),
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
  const _ResetButton({this.onTap, this.onLongPress, required this.label});

  /// Exactly one of these is set. A destructive action gets [onLongPress] and
  /// NEVER [onTap] — C0 was a plain tap wiping a trip counter.
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
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
            onLongPress: onLongPress,
            child: Container(
              height: 56,
              alignment: Alignment.center,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  // DAY token. RST A/B sits ON THE CLUSTER, which is the
                  // screen night mode exists for.
                  color: onLongPress != null
                      ? AppColors.danger
                      : InstrumentColors.of(context).secondary,
                  fontSize: onLongPress != null ? 11 : 15,
                  height: 1.15,
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
