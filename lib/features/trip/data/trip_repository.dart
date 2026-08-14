import '../../../core/storage/storage_service.dart';
import '../domain/trip_state.dart';

/// Persists trip/odometer values. Survives app restart and process death.
class TripRepository {
  TripRepository(this._storage);
  final StorageService _storage;

  TripState load() {
    return TripState(
      tripA: _storage.read(StorageKeys.tripA, 0.0),
      tripB: _storage.read(StorageKeys.tripB, 0.0),
      odometer: _storage.read(StorageKeys.odometer, 0.0),
    );
  }

  /// ONE write, not three.
  ///
  /// This was three sequential `put`s, so a process kill between them left a
  /// PARTIAL state on disk: Trip A reset and the odometer not, or a tunnel
  /// correction landed on one counter and not the others. The three values are
  /// a single fact about the vehicle and have to move together.
  ///
  /// `putAll` commits them in one Hive transaction, so a reader sees either all
  /// three or none. Codex round 2.
  Future<void> save(TripState s) => _storage.writeAll({
        StorageKeys.tripA: s.tripA,
        StorageKeys.tripB: s.tripB,
        StorageKeys.odometer: s.odometer,
      });
}
