import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/formatters.dart';
import '../../../settings/presentation/providers/settings_providers.dart';
import '../../../trip/domain/trip_state.dart';
import '../../../trip/presentation/providers/trip_providers.dart';
import 'instrument_box.dart';

/// A single trip counter readout with a large value and a reset on long-press.
class TripReadout extends ConsumerWidget {
  const TripReadout({super.key, required this.counter});

  final TripCounter counter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metric = ref.watch(isMetricProvider);
    final meters = counter == TripCounter.a
        ? ref.watch(tripAProvider)
        : ref.watch(tripBProvider);
    final colors = InstrumentColors.of(context);
    final label = counter == TripCounter.a ? 'TRIP A' : 'TRIP B';

    return InstrumentBox(
      label: label,
      accent: counter == TripCounter.a ? AppColors.accent : null,
      onTap: () => _confirmReset(context, ref),
      child: Row(
        // Shrink-wrap: InstrumentBox scales the whole value area to fit the
        // tile, so a flex child here would ask it for infinite width.
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            Formatters.trip(meters, metric: metric),
            style: Theme.of(context).textTheme.displaySmall?.copyWith(color: colors.primary),
          ),
          const SizedBox(width: 6),
          Text(
            Formatters.tripUnit(metric: metric),
            style: TextStyle(color: colors.secondary, fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  void _confirmReset(BuildContext context, WidgetRef ref) {
    ref.read(tripProvider.notifier).resetTrip(counter);
  }
}

/// Lifetime odometer (read-only, smaller).
class OdometerReadout extends ConsumerWidget {
  const OdometerReadout({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metric = ref.watch(isMetricProvider);
    final meters = ref.watch(odometerProvider);
    final colors = InstrumentColors.of(context);
    return InstrumentBox(
      label: 'ODO',
      child: Text(
        Formatters.distance(meters, metric: metric),
        style: TextStyle(
          color: colors.primary,
          fontSize: 28,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
