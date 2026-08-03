import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/di/providers.dart';
import '../../../distance/domain/distance_delta.dart';
import '../../../distance/presentation/providers/distance_providers.dart';
import '../../../settings/presentation/providers/settings_providers.dart';
import '../../data/trip_repository.dart';
import '../../domain/trip_state.dart';

final tripRepositoryProvider = Provider<TripRepository>((ref) {
  return TripRepository(ref.watch(storageProvider));
});

/// Core trip computer. Integrates calibrated ground distance from the DISTANCE
/// ENGINE and accumulates Trip A, Trip B and the lifetime odometer.
///
/// The engine is the source of truth for *how far*, and for *where that came
/// from*: GPS in the open, a sensor estimate inside a tunnel, or a smoothed
/// post-tunnel correction. The trip computer stays deliberately ignorant of the
/// distinction — it just adds metres. That is what let tunnel handling arrive
/// without touching this integration at all.
///
/// The rally-grade reliability rules this used to implement inline (accuracy
/// gating, dropout re-anchoring, teleport rejection, the sub-[minMovementMeters]
/// standstill floor) now live once in `GpsDistanceSource`, shared with the
/// average-speed integrator so the two cannot drift apart.
///
/// Still owned here:
///  • Calibration — the rally correction factor is a trip-computer concern.
///  • Persistence — at most every [tripPersistInterval]; also on every manual
///    edit and on dispose → survives restart without thrashing flash.
class TripController extends Notifier<TripState> {
  late final TripRepository _repo;

  DateTime _lastPersist = DateTime.fromMillisecondsSinceEpoch(0);
  bool _dirty = false;

  @override
  TripState build() {
    _repo = ref.watch(tripRepositoryProvider);

    // Integrate every distance increment as it arrives.
    ref.listen<AsyncValue<DistanceDelta>>(distanceDeltaProvider, (_, next) {
      final delta = next.valueOrNull;
      if (delta != null) _onDelta(delta);
    });

    // Flush to disk when this provider is torn down (app close / hot restart).
    ref.onDispose(() {
      if (_dirty) _repo.save(state);
    });

    return _repo.load();
  }

  void _onDelta(DistanceDelta d) {
    // A zero-metre delta is a real, accepted event (the car is stopped) — it
    // just moves no distance. Skip it before dirtying state so a standstill
    // can't churn writes to flash.
    if (!(d.meters > 0)) return;

    final calibrated = d.meters * ref.read(calibrationProvider);
    state = state.copyWith(
      tripA: state.tripA + calibrated,
      tripB: state.tripB + calibrated,
      odometer: state.odometer + calibrated,
    );
    _markDirtyAndMaybePersist();
  }

  void _markDirtyAndMaybePersist() {
    _dirty = true;
    final now = DateTime.now();
    if (now.difference(_lastPersist) >= AppConstants.tripPersistInterval) {
      _persistNow();
    }
  }

  void _persistNow() {
    _lastPersist = DateTime.now();
    _dirty = false;
    _repo.save(state);
  }

  // ---- User actions (persist immediately — these are deliberate edits) ----

  void resetTrip(TripCounter counter) {
    state = counter == TripCounter.a
        ? state.copyWith(tripA: 0)
        : state.copyWith(tripB: 0);
    _persistNow();
  }

  void resetOdometer() {
    state = state.copyWith(odometer: 0);
    _persistNow();
  }

  /// Manual roadbook correction (e.g. +100 m / -10 m). Clamped at zero so a
  /// trip never goes negative. Odometer is left untouched (lifetime total).
  void adjust(TripCounter counter, double meters) {
    if (counter == TripCounter.a) {
      state = state.copyWith(tripA: (state.tripA + meters).clamp(0, double.infinity));
    } else {
      state = state.copyWith(tripB: (state.tripB + meters).clamp(0, double.infinity));
    }
    _persistNow();
  }
}

final tripProvider =
    NotifierProvider<TripController, TripState>(TripController.new);

/// Per-counter slices so a Trip A edit doesn't rebuild the Trip B widget.
final tripAProvider =
    Provider<double>((ref) => ref.watch(tripProvider.select((t) => t.tripA)));
final tripBProvider =
    Provider<double>((ref) => ref.watch(tripProvider.select((t) => t.tripB)));
final odometerProvider =
    Provider<double>((ref) => ref.watch(tripProvider.select((t) => t.odometer)));
