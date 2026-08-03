import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/di/providers.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/formatters.dart';
import '../../data/settings_repository.dart';
import '../../domain/settings_state.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository(ref.watch(storageProvider));
});

/// Single source of truth for app configuration. Writes persist immediately
/// (settings change rarely; durability matters more than batching here).
class SettingsController extends Notifier<SettingsState> {
  late final SettingsRepository _repo;

  @override
  SettingsState build() {
    _repo = ref.watch(settingsRepositoryProvider);
    return _repo.load();
  }

  void toggleDisplayMode() {
    final next = state.isNight ? DisplayMode.day : DisplayMode.night;
    state = state.copyWith(displayMode: next);
    _repo.saveDisplayMode(next);
  }

  void toggleSpeedUnit() {
    final next = state.isMetric ? SpeedUnit.mph : SpeedUnit.kmh;
    state = state.copyWith(speedUnit: next);
    _repo.saveSpeedUnit(next);
  }

  void setCalibration(double factor) {
    final clamped =
        factor.clamp(AppConstants.minCalibration, AppConstants.maxCalibration);
    state = state.copyWith(calibration: clamped);
    _repo.saveCalibration(clamped);
  }

  void nudgeCalibration(double delta) => setCalibration(state.calibration + delta);

  void toggleTrueNorth() {
    final next = !state.useTrueNorth;
    state = state.copyWith(useTrueNorth: next);
    _repo.saveTrueNorth(next);
  }

  /// Lock mode is session-only (not persisted).
  void setLocked(bool value) => state = state.copyWith(locked: value);
  void toggleLock() => setLocked(!state.locked);
}

final settingsProvider =
    NotifierProvider<SettingsController, SettingsState>(SettingsController.new);

/// Fine-grained slices to minimise rebuilds.
final isMetricProvider =
    Provider<bool>((ref) => ref.watch(settingsProvider.select((s) => s.isMetric)));
final speedUnitProvider =
    Provider<SpeedUnit>((ref) => ref.watch(settingsProvider.select((s) => s.speedUnit)));
final isNightProvider =
    Provider<bool>((ref) => ref.watch(settingsProvider.select((s) => s.isNight)));
final isLockedProvider =
    Provider<bool>((ref) => ref.watch(settingsProvider.select((s) => s.locked)));
final calibrationProvider =
    Provider<double>((ref) => ref.watch(settingsProvider.select((s) => s.calibration)));
