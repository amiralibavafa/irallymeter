import 'package:hive_flutter/hive_flutter.dart';

/// Thin wrapper over Hive. We deliberately store only primitives and JSON
/// strings so the app needs no generated TypeAdapters / build_runner — this
/// keeps the build reproducible and removes a whole class of codegen failures
/// in a tool that has to be reliable.
class StorageService {
  StorageService._(this._box);

  static const String _boxName = 'irallymeter';
  final Box _box;

  static Future<StorageService> init() async {
    await Hive.initFlutter();
    final box = await Hive.openBox(_boxName);
    return StorageService._(box);
  }

  T read<T>(String key, T fallback) {
    final value = _box.get(key);
    if (value is T) return value;
    return fallback;
  }

  Future<void> write(String key, Object? value) => _box.put(key, value);

  Future<void> delete(String key) => _box.delete(key);

  List<String> readStringList(String key) {
    final raw = _box.get(key);
    if (raw is List) return raw.cast<String>();
    return const [];
  }

  Future<void> writeStringList(String key, List<String> values) =>
      _box.put(key, values);
}

/// Hive keys in one place to avoid typo-driven data loss.
class StorageKeys {
  StorageKeys._();

  static const String tripA = 'trip_a_m';
  static const String tripB = 'trip_b_m';
  static const String odometer = 'odometer_m';
  static const String calibration = 'calibration_factor';
  static const String displayMode = 'display_mode'; // 'day' | 'night'
  static const String speedUnit = 'speed_unit'; // 'kmh' | 'mph'
  static const String trueNorth = 'use_true_north'; // bool
  static const String lastLat = 'last_lat';
  static const String lastLng = 'last_lng';
  static const String sessions = 'route_sessions'; // List<String> of JSON

  /// The learned magnetic-to-true heading offset, and how many observations
  /// stand behind it. Written only once the calibration is LEARNED — see
  /// `HeadingCalibrationRepository`.
  static const String headingOffsetDeg = 'heading_offset_deg';
  static const String headingSamples = 'heading_samples';

  /// Whether the permission rationale has been shown and acted on. Set once the
  /// user has been through it, whether they granted anything or not — the
  /// screen explains, it does not enforce, so re-showing it would only nag.
  static const String onboarded = 'onboarded'; // bool
}
