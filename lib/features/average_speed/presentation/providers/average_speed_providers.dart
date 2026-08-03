import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../distance/domain/distance_delta.dart';
import '../../../distance/presentation/providers/distance_providers.dart';
import '../../domain/average_speed_calculator.dart';

/// Immutable snapshot of the average-speed integrator for the UI to render.
class AverageSpeedState {
  const AverageSpeedState({
    required this.averageMps,
    required this.distanceMeters,
    required this.elapsed,
  });

  final double averageMps;
  final double distanceMeters;
  final Duration elapsed;

  static const zero =
      AverageSpeedState(averageMps: 0, distanceMeters: 0, elapsed: Duration.zero);
}

/// Drives an [AverageSpeedCalculator] from the DISTANCE ENGINE (the same source
/// the trip computer integrates), so the average accumulates app-wide
/// regardless of which screen is showing. Decoupled from the trip counters so
/// resetting the average never touches Trip A/B or the odometer.
///
/// Consuming engine deltas rather than raw fixes is what keeps the average
/// alive through a tunnel: sensor-estimated increments carry both distance and
/// time, so the readout keeps integrating instead of freezing at its last value.
class AverageSpeedController extends Notifier<AverageSpeedState> {
  final AverageSpeedCalculator _calc = AverageSpeedCalculator();

  @override
  AverageSpeedState build() {
    ref.listen<AsyncValue<DistanceDelta>>(distanceDeltaProvider, (_, next) {
      final delta = next.valueOrNull;
      if (delta == null) return;
      _calc.addDelta(delta);
      state = _snapshot();
    });
    return AverageSpeedState.zero;
  }

  AverageSpeedState _snapshot() => AverageSpeedState(
        averageMps: _calc.averageMps,
        distanceMeters: _calc.distanceMeters,
        elapsed: _calc.elapsed,
      );

  /// Start a fresh leg (e.g. a new stage). Clears distance + time.
  void reset() {
    _calc.reset();
    state = AverageSpeedState.zero;
  }
}

final averageSpeedProvider =
    NotifierProvider<AverageSpeedController, AverageSpeedState>(
        AverageSpeedController.new);

/// Fine-grained slice so the dashboard widget only rebuilds on average change.
final averageSpeedMpsProvider = Provider<double>(
    (ref) => ref.watch(averageSpeedProvider.select((s) => s.averageMps)));
