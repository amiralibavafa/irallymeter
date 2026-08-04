import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../gps/domain/gps_sample.dart';
import '../../../gps/presentation/providers/gps_providers.dart';
import '../../data/sensors_motion_service.dart';
import '../../domain/distance_delta.dart';
import '../../domain/distance_engine.dart';
import '../../domain/distance_engine_state.dart';
import '../../domain/measurement_status.dart';
import '../../domain/motion_repository.dart';
import '../../../replay/domain/simulated_drive.dart';
import '../../../replay/presentation/simulation_provider.dart';
import '../../domain/motion_sample.dart';

/// DI seam: swap for a fake motion source in tests or simulation mode — the
/// same pattern [gpsRepositoryProvider] uses.
final motionRepositoryProvider = Provider<MotionRepository>((ref) {
  // See gpsRepositoryProvider: the simulated drive has to replace BOTH sources
  // or the engine would be handed real accelerometer noise from a stationary
  // desk while being told it is doing 90 km/h through a tunnel.
  if (simulationActiveRef(ref)) return SimulatedMotionRepository();
  final service = SensorsMotionService();
  ref.onDispose(service.dispose);
  return service;
});

/// Motion samples from the phone's inertial sensors.
///
/// Errors are swallowed rather than propagated: on a device with no usable
/// sensors the tunnel fallback should quietly not be available, not take the
/// distance engine down with it.
final motionStreamProvider = StreamProvider<MotionSample>((ref) {
  return ref.watch(motionRepositoryProvider).motionStream().handleError((_) {});
});

/// The distance engine — the single arbiter of "how far have we travelled".
///
/// Owns the [DistanceEngine] and feeds it the three inputs it needs: raw GPS
/// fixes, motion samples, and a heartbeat. Its state is what the UI watches to
/// show GPS/tunnel status; the increments it produces go out on
/// [distanceDeltaProvider].
///
/// This provider is the reason tunnel handling didn't have to be bolted onto
/// the trip computer and the average-speed integrator separately.
///
/// INVARIANT: [build] must never `ref.watch`. It uses `ref.listen` throughout
/// so it runs exactly once, which is what lets the engine and its delta stream
/// be created as fields and torn down in `onDispose`. A `watch` would re-run
/// `build`, closing the stream that consumers are still subscribed to while
/// leaving the `late final` engine behind — use `ref.listen` or read inside a
/// callback instead.
class DistanceEngineController extends Notifier<DistanceEngineState> {
  late final DistanceEngine _engine;
  final StreamController<DistanceDelta> _deltas =
      StreamController<DistanceDelta>.broadcast();
  Timer? _ticker;

  /// Every distance increment, whatever its source.
  Stream<DistanceDelta> get deltas => _deltas.stream;

  @override
  DistanceEngineState build() {
    _engine = DistanceEngine(
      onDelta: (d) {
        if (!_deltas.isClosed) _deltas.add(d);
      },
      onState: (s) => state = s,
    );

    // Raw fixes, not the smoothed display state — the engine does its own
    // filtering and must see the exact fix sequence, matching how the trip
    // computer has always consumed GPS.
    ref.listen<AsyncValue<GpsSample>>(rawGpsStreamProvider, (_, next) {
      final s = next.valueOrNull;
      if (s != null) _engine.onGpsSample(s, DateTime.now());
    });

    ref.listen<AsyncValue<MotionSample>>(motionStreamProvider, (_, next) {
      final m = next.valueOrNull;
      if (m != null) _engine.onMotionSample(m, DateTime.now());
    });

    // Heartbeat: dropout detection can't be driven by samples that aren't
    // arriving, and reconciliation pays out against the wall clock.
    _ticker = Timer.periodic(
      AppConstants.engineTick,
      (_) => _engine.tick(DateTime.now()),
    );

    ref.onDispose(() {
      _ticker?.cancel();
      _deltas.close();
    });

    return DistanceEngineState.initial;
  }

}

final distanceEngineProvider =
    NotifierProvider<DistanceEngineController, DistanceEngineState>(
        DistanceEngineController.new);

/// The stream of distance increments the trip computer and average-speed
/// integrator consume instead of raw GPS.
///
/// Watches the engine's *notifier* (stable identity) rather than its state, so
/// an engine state change doesn't tear down and resubscribe this stream.
final distanceDeltaProvider = StreamProvider<DistanceDelta>((ref) {
  return ref.watch(distanceEngineProvider.notifier).deltas;
});

// ---- Fine-grained slices — widgets watch only what they render ----

/// True while GPS is unusable and distance is being estimated from sensors.
final tunnelModeProvider = Provider<bool>(
    (ref) => ref.watch(distanceEngineProvider.select((s) => s.tunnelMode)));

/// True while a post-tunnel correction is being paid out.
final reconcilingProvider = Provider<bool>(
    (ref) => ref.watch(distanceEngineProvider.select((s) => s.reconciling)));

/// The active distance source.
final distanceSourceProvider = Provider<DistanceSource>(
    (ref) => ref.watch(distanceEngineProvider.select((s) => s.source)));

/// Speed for the hero readout: the sensor estimate while in a tunnel, the
/// smoothed GPS speed otherwise.
///
/// Without this the speedometer would FREEZE at its last value on tunnel entry
/// — `gpsStateProvider` simply holds its last state when fixes stop arriving,
/// which reads as "still doing 90" rather than "estimating". Deliberately lives
/// here rather than in `gps_providers.dart`: the distance feature depends on
/// the GPS feature, and reversing that to let the GPS layer consult the engine
/// would invert the dependency.
final displaySpeedMpsProvider = Provider<double>((ref) {
  final tunnel = ref.watch(tunnelModeProvider);
  if (tunnel) {
    return ref.watch(distanceEngineProvider.select((s) => s.speedMps));
  }
  return ref.watch(speedMpsProvider);
});

/// 1 Hz heartbeat for display state that depends on ELAPSED TIME rather than on
/// anything the engine publishes.
///
/// Overridable, and it has to be: an unbounded `Stream.periodic` outlives the
/// widget tree and trips the pending-timer check, which is the same reason
/// `gpsDropoutProvider` is pinned in `dashboard_layout_test`.
final displayTickProvider = StreamProvider<int>(
    (ref) => Stream<int>.periodic(const Duration(seconds: 1), (i) => i));

/// SPEC-v2 §5.1 — whether the numbers on screen are measured or guessed.
///
/// Watches [displayTickProvider] as well as the engine, because §12.3's
/// confidence decay is a function of how long Estimation Mode has been running.
/// Nothing about the engine's state changes while it coasts, so a provider that
/// rebuilt only on engine changes would sit on "normal confidence" for three
/// minutes and never escalate the warning.
final measurementStatusProvider = Provider<MeasurementStatus>((ref) {
  final s = ref.watch(distanceEngineProvider);
  ref.watch(displayTickProvider);
  return MeasurementStatus.from(s, DateTime.now());
});
