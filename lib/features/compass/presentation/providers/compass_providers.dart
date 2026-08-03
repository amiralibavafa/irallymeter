import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../gps/presentation/providers/gps_providers.dart';
import '../../../settings/presentation/providers/settings_providers.dart';
import '../../data/compass_service.dart';

final compassServiceProvider = Provider<CompassService>((ref) {
  final service = CompassService();
  ref.onDispose(service.dispose);
  return service;
});

/// Raw magnetic heading from the sensor fusion service.
final magneticHeadingProvider = StreamProvider<double>((ref) {
  return ref.watch(compassServiceProvider).headingStream();
});

/// Unified CAP heading shown on the dashboard.
///
/// Rally-correct fusion: when moving, GPS course-over-ground is true-north
/// referenced and far more stable than a magnetometer near steel/electronics,
/// so we prefer it. When stationary (no GPS course), fall back to the
/// magnetic compass. The "true north" toggle only matters for the magnetic
/// branch label; GPS course is already true.
final capHeadingProvider = Provider<double>((ref) {
  final gpsHeading = ref.watch(headingProvider); // smoothed GPS course (NaN if stopped)
  if (gpsHeading.isFinite) return gpsHeading;
  final mag = ref.watch(magneticHeadingProvider).valueOrNull;
  return mag ?? double.nan;
});

/// Whether the heading currently comes from GPS course vs magnetic sensor.
final headingSourceProvider = Provider<String>((ref) {
  final gpsHeading = ref.watch(headingProvider);
  if (gpsHeading.isFinite) return 'GPS';
  return ref.watch(settingsProvider.select((s) => s.useTrueNorth)) ? 'TRUE' : 'MAG';
});
