import '../../../core/storage/storage_service.dart';
import '../domain/trip_state.dart';

/// Persists trip/odometer values. Survives app restart and process death.
class TripRepository {
  TripRepository(this._storage);
  final StorageService _storage;

  /// ONE key, ONE value.
  ///
  /// This was three keys, then one `putAll`, and NEITHER was crash-atomic.
  /// Hive 2.2.3 encodes a `putAll` as three INDEPENDENT FRAMES, and recovery
  /// accepts every complete frame before a truncated one — so a kill mid-batch
  /// could still persist Trip A and lose the odometer, exactly as three
  /// separate writes could. Codex round 3.
  ///
  /// A single value under a single key is one frame: it is either recovered
  /// whole or not at all, which is the actual contract these three numbers
  /// need. They are one fact about the vehicle.
  TripState load() {
    final snap = _storage.read<Map?>(StorageKeys.tripSnapshot, null);
    if (snap != null) {
      return TripState(
        tripA: _num(snap['a']),
        tripB: _num(snap['b']),
        odometer: _num(snap['o']),
      );
    }

    // MIGRATION from the three legacy keys. Without this, upgrading resets a
    // crew's odometer to zero — silent data loss on the one counter that
    // cannot be recovered. Read-only: the next save writes the new shape.
    return TripState(
      tripA: _storage.read(StorageKeys.tripA, 0.0),
      tripB: _storage.read(StorageKeys.tripB, 0.0),
      odometer: _storage.read(StorageKeys.odometer, 0.0),
    );
  }

  static double _num(Object? v) {
    final d = v is num ? v.toDouble() : 0.0;
    return d.isFinite && d >= 0 ? d : 0.0;
  }

  Future<void> save(TripState s) => _storage.write(
        StorageKeys.tripSnapshot,
        {'a': s.tripA, 'b': s.tripB, 'o': s.odometer},
      );
}
