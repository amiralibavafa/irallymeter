import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/formatters.dart';
import '../../../settings/presentation/providers/settings_providers.dart';
import '../../../trip/domain/trip_state.dart';
import '../../../trip/presentation/providers/trip_providers.dart';
import '../../../distance/domain/measurement_status.dart';
import '../../../distance/presentation/providers/distance_providers.dart';
import 'instrument_box.dart';
import 'measurement_badge.dart';

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
    final status = ref.watch(measurementStatusProvider);

    // SPEC-v2 §5.1. The trip counters matter most of all here: this is the
    // number a co-driver reads aloud, so it must never be ambiguous about
    // whether it was measured or dead-reckoned.
    final digitColor = switch (status.state) {
      MeasurementState.measured => colors.primary,
      MeasurementState.reconciling => AppColors.info,
      MeasurementState.estimated =>
        status.isLowConfidence ? AppColors.danger : AppColors.warn,
    };

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
            style: Theme.of(context).textTheme.displaySmall?.copyWith(color: digitColor),
          ),
          const SizedBox(width: 6),
          Text(
            Formatters.tripUnit(metric: metric),
            style: TextStyle(color: colors.secondary, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          if (status.badge != null) ...[
            const SizedBox(width: 6),
            MeasurementBadge(status: status, compact: true),
          ],
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
    // §5.1: the odometer integrates the same delta stream as the trips, so it
    // carries estimated metres too and must say so.
    final status = ref.watch(measurementStatusProvider);
    final odoColor = switch (status.state) {
      MeasurementState.measured => colors.primary,
      MeasurementState.reconciling => AppColors.info,
      MeasurementState.estimated =>
        status.isLowConfidence ? AppColors.danger : AppColors.warn,
    };
    return InstrumentBox(
      label: 'ODO',
      child: Text(
        // Matches Trip A/B rather than `Formatters.distance`, which switched
        // between "0 m" and "12.34 km" as the value grew. Three distance
        // readouts sit side by side on the cluster, and having one of them in a
        // different unit and precision made a co-driver switch units
        // mid-glance — and the format CHANGED under them as the odo climbed.
        '${Formatters.trip(meters, metric: metric)} '
            '${Formatters.tripUnit(metric: metric)}',
        style: TextStyle(
          color: odoColor,
          fontSize: 28,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
