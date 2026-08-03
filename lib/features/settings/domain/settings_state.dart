import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';

/// User-facing configuration. Immutable; persisted field-by-field in Hive.
class SettingsState {
  const SettingsState({
    required this.displayMode,
    required this.speedUnit,
    required this.calibration,
    required this.useTrueNorth,
    required this.locked,
  });

  final DisplayMode displayMode;
  final SpeedUnit speedUnit;

  /// Multiplier applied to raw GPS distance (rally wheel/route calibration).
  final double calibration;

  /// Compass shows true north vs magnetic when true.
  final bool useTrueNorth;

  /// Lock mode — UI ignores accidental touches while driving.
  final bool locked;

  bool get isMetric => speedUnit == SpeedUnit.kmh;
  bool get isNight => displayMode == DisplayMode.night;

  SettingsState copyWith({
    DisplayMode? displayMode,
    SpeedUnit? speedUnit,
    double? calibration,
    bool? useTrueNorth,
    bool? locked,
  }) {
    return SettingsState(
      displayMode: displayMode ?? this.displayMode,
      speedUnit: speedUnit ?? this.speedUnit,
      calibration: calibration ?? this.calibration,
      useTrueNorth: useTrueNorth ?? this.useTrueNorth,
      locked: locked ?? this.locked,
    );
  }

  static const SettingsState defaults = SettingsState(
    displayMode: DisplayMode.day,
    speedUnit: SpeedUnit.kmh,
    calibration: 1.0,
    useTrueNorth: false,
    locked: false,
  );
}
