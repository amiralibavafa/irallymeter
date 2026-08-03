import '../../../core/storage/storage_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../domain/settings_state.dart';

/// Loads/saves [SettingsState] as primitives in Hive (no adapters).
class SettingsRepository {
  SettingsRepository(this._storage);
  final StorageService _storage;

  SettingsState load() {
    return SettingsState(
      displayMode:
          _storage.read(StorageKeys.displayMode, 'day') == 'night'
              ? DisplayMode.night
              : DisplayMode.day,
      speedUnit: SpeedUnitLabel.fromStorage(
          _storage.read(StorageKeys.speedUnit, 'kmh')),
      calibration: _storage.read(StorageKeys.calibration, 1.0),
      useTrueNorth: _storage.read(StorageKeys.trueNorth, false),
      // Lock state is intentionally not persisted — always start unlocked.
      locked: false,
    );
  }

  Future<void> saveDisplayMode(DisplayMode mode) =>
      _storage.write(StorageKeys.displayMode, mode == DisplayMode.night ? 'night' : 'day');

  Future<void> saveSpeedUnit(SpeedUnit unit) =>
      _storage.write(StorageKeys.speedUnit, unit.storageKey);

  Future<void> saveCalibration(double factor) =>
      _storage.write(StorageKeys.calibration, factor);

  Future<void> saveTrueNorth(bool value) =>
      _storage.write(StorageKeys.trueNorth, value);
}
