import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../gps/presentation/providers/gps_providers.dart';
import '../../../settings/presentation/providers/settings_providers.dart';
import '../../data/compass_service.dart';
import '../../domain/heading_calibration.dart';

final compassServiceProvider = Provider<CompassService>((ref) {
  final service = CompassService();
  ref.onDispose(service.dispose);
  return service;
});

/// Raw magnetic heading from the sensor fusion service.
final magneticHeadingProvider = StreamProvider<double>((ref) {
  return ref.watch(compassServiceProvider).headingStream();
});

/// Learns the magnetic → true offset from the app's own GPS course.
///
/// GPS course over ground is true-north referenced, so whenever the vehicle is
/// moving on a good fix the difference between it and the magnetometer IS the
/// correction — declination and this car's own hard-iron distortion together,
/// in one number, with no magnetic model and no network.
final headingCalibrationProvider = Provider<HeadingCalibration>((ref) {
  final cal = HeadingCalibration();

  // Fold in pairs as they arrive. `listen`, not `watch`: this provider must
  // keep its learned state rather than being rebuilt on every fix.
  ref.listen(gpsStateProvider, (_, next) {
    final gps = next.valueOrNull;
    if (gps == null) return;
    final mag = ref.read(magneticHeadingProvider).valueOrNull;
    if (mag == null) return;
    cal.observe(
      gpsCourseDeg: gps.headingDeg,
      magneticDeg: mag,
      speedMps: gps.smoothedSpeedMps,
      accuracyM: gps.accuracyM,
    );
  });

  return cal;
});

/// Unified CAP heading shown on the dashboard.
///
/// Rally-correct fusion: when moving, GPS course-over-ground is true-north
/// referenced and far more stable than a magnetometer near steel/electronics,
/// so we prefer it. When stationary (no GPS course), fall back to the magnetic
/// compass.
///
/// The magnetic branch is corrected to true north ONLY once
/// [headingCalibrationProvider] has learned the offset. Before that the raw
/// magnetic heading is shown and [headingSourceProvider] says MAG, because the
/// alternative — relabelling an uncorrected reading as TRUE — is what this
/// cluster used to do, and a display that asserts something false is worse than
/// one that admits it does not know.
final capHeadingProvider = Provider<double>((ref) {
  final gpsHeading = ref.watch(headingProvider); // NaN when stopped
  if (gpsHeading.isFinite) return gpsHeading;

  final mag = ref.watch(magneticHeadingProvider).valueOrNull;
  if (mag == null) return double.nan;

  final wantsTrue = ref.watch(settingsProvider.select((s) => s.useTrueNorth));
  if (!wantsTrue) return mag;
  return ref.watch(headingCalibrationProvider).toTrue(mag);
});

/// Whether the heading currently comes from GPS course vs the magnetic sensor,
/// and — crucially — whether it is genuinely true-north referenced.
///
/// `TRUE` is now earned rather than asserted: it appears only when the user
/// asked for true north AND the offset has actually been learned. Otherwise the
/// cluster says `MAG`, which is what it is.
final headingSourceProvider = Provider<String>((ref) {
  if (ref.watch(headingProvider).isFinite) return 'GPS';

  final wantsTrue = ref.watch(settingsProvider.select((s) => s.useTrueNorth));
  if (!wantsTrue) return 'MAG';
  return ref.watch(headingCalibrationProvider).isLearned ? 'TRUE' : 'MAG';
});
