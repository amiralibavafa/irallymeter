import 'package:flutter/foundation.dart';
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

    // A CORRECTION IS PERSISTED IMMEDIATELY, ordinary movement is throttled.
    //
    // `dt == Duration.zero` is what `DistanceDelta.correction` produces, and a
    // correction is the post-tunnel residual: rare, large, and unrepeatable.
    //
    // Since the payout became INSTANT it arrives as ONE delta and the
    // reconciler then holds nothing. Ordinary throttling only flushes on
    // further movement, so a car that stops at the tunnel mouth could leave the
    // whole correction dirty in memory until the process died, rolling the
    // counters back to their pre-tunnel values. The smooth payout hid this by
    // accident, emitting deltas for 15-60 s one of which crossed the interval;
    // removing the drip removed the accident, so the durability has to be
    // deliberate. Found by Codex on the SA-V3 review.
    if (d.dt == Duration.zero) {
      _persistNow();
    } else {
      _markDirtyAndMaybePersist();
    }
  }

  /// Feed one delta as the engine would. Test-only seam for the correction
  /// durability path, which is otherwise only reachable through a live tunnel.
  @visibleForTesting
  void debugApplyDelta(DistanceDelta d) => _onDelta(d);

  void _markDirtyAndMaybePersist() {
    _dirty = true;
    final now = DateTime.now();
    if (now.difference(_lastPersist) >= AppConstants.tripPersistInterval) {
      _persistNow();
    }
  }

  /// Returns the write so a DESTRUCTIVE action can await it. Fire-and-forget is
  /// fine for routine throttled saves; it is not fine for a reset, which must
  /// not report success before it is durable.
  /// Clears `_dirty` only ON SUCCESS.
  ///
  /// It used to clear optimistically, before the write completed. So a failed
  /// or interrupted write left `_dirty == false` with unsaved distance in
  /// memory and NOTHING TO TRIGGER A RETRY — the next throttled save saw
  /// nothing owing. For a post-tunnel correction, which is consumed from the
  /// reconciler and never re-emitted, that silently lost the whole tunnel.
  ///
  /// Four review rounds patched WHERE saves happen (three keys, then putAll,
  /// then one key). None of that mattered while the completion contract itself
  /// was wrong: a durable write means the flag drops when the bytes land, not
  /// when the call is made.
  Future<void> _persistNow() {
    final pending = state;
    _lastPersist = DateTime.now();
    return _repo.save(pending).then((_) {
      // Only claim it is clean if nothing further changed while we wrote.
      if (identical(state, pending)) _dirty = false;
    }, onError: (Object e, StackTrace st) {
      // Stay dirty so the ordinary throttled path tries again. Losing measured
      // distance without a word is the failure this exists to prevent.
      _dirty = true;
      // ignore: avoid_print
      print('iRallyMeter: trip save failed ($e) — staying dirty for retry');
    });
  }

  // ---- User actions (persist immediately — these are deliberate edits) ----

  void resetTrip(TripCounter counter) {
    // Settle any outstanding tunnel correction FIRST. Those metres were covered
    // before this reset, so they belong to the leg that is ending — left in the
    // reconciler they would drip into the new leg over the next 15-60 s and
    // silently inflate it by up to several hundred metres.
    final owed = _settleOwedMetres();
    state = state.copyWith(
      tripA: counter == TripCounter.a ? 0 : state.tripA + owed,
      tripB: counter == TripCounter.b ? 0 : state.tripB + owed,
      odometer: state.odometer + owed,
    );
    _persistNow();
  }

  /// Flush the reconciler and return the calibrated metres it owed.
  double _settleOwedMetres() {
    final raw = ref.read(distanceEngineProvider.notifier).settleReconciliation();
    if (!raw.isFinite || raw <= 0) return 0;
    return raw * ref.read(calibrationProvider);
  }

  /// Zero EVERYTHING — both trips and the lifetime odometer.
  ///
  /// Asked for by Amirali's father after the first real road test and confirmed
  /// twice, because it is irreversible.
  ///
  /// ## It is a LONG PRESS, not a tap, and that is deliberate
  ///
  /// The odometer is the vehicle's lifetime total. Nothing restores it and no
  /// undo exists. C0 — the worst defect found in this app — was a plain tap
  /// zeroing ONE trip counter, so putting a wipe-everything action on a tap
  /// would reintroduce C0 with a far larger blast radius. The button reads
  /// "RST ALL / HOLD" so the gesture is discoverable rather than hidden.
  ///
  /// ## What "speed" means in the request
  ///
  /// The live speedometer cannot be zeroed: it is a GPS reading, so it would
  /// blank for a fraction of a second and the next fix would restore it. The
  /// AVERAGE speed is an accumulator like the trips, so that is what is cleared,
  /// by the caller, which owns that provider.
  Future<void> resetAll() {
    // Flush the reconciler for the same reason [resetTrip] does: those metres
    // were covered BEFORE this reset, so leaving them queued would drip them
    // into the freshly zeroed counters over the following seconds and a "reset
    // everything" would quietly not stay at zero.
    _settleOwedMetres();
    final cleared = state.copyWith(tripA: 0, tripB: 0, odometer: 0);
    // PERSIST FIRST, THEN PUBLISH.
    //
    // Awaiting the write was not enough on its own: the state was published
    // before it, and `InkWell.onLongPress` is a `VoidCallback` so Flutter never
    // observes the returned Future anyway. The screen could therefore show zero
    // while the write was still pending, or had failed — and a failed write
    // leaves zero on screen with the old values returning after a restart.
    //
    // Writing first inverts that: the counters only read zero once zero is what
    // is on disk. On failure the exception propagates and the display still
    // shows the real values, which is the honest outcome. Codex round 3.
    return _repo.save(cleared).then((_) {
      _lastPersist = DateTime.now();
      _dirty = false;
      state = cleared;
    });
  }

  void resetOdometer() {
    // Same reasoning as resetTrip: flush first so the trips still receive what
    // was already covered, then zero the odometer.
    final owed = _settleOwedMetres();
    state = state.copyWith(
      tripA: state.tripA + owed,
      tripB: state.tripB + owed,
      odometer: 0,
    );
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
