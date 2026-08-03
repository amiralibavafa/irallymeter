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

  Future<void> save(TripState s) async {
    await _storage.write(StorageKeys.tripA, s.tripA);
    await _storage.write(StorageKeys.tripB, s.tripB);
    await _storage.write(StorageKeys.odometer, s.odometer);
  }
}
