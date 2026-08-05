import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../gps/presentation/providers/gps_providers.dart';
import '../../../settings/presentation/providers/settings_providers.dart';
import '../../data/compass_service.dart';
import '../../data/heading_calibration_repository.dart';
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
final headingCalibrationRepositoryProvider =
    Provider<HeadingCalibrationRepository>(
        (ref) => HeadingCalibrationRepository(ref.watch(storageProvider)));

final headingCalibrationProvider = Provider<HeadingCalibration>((ref) {
  final repo = ref.watch(headingCalibrationRepositoryProvider);
  final cal = HeadingCalibration();

  // Carry the previous session's offset over. `restore` deliberately does not
  // carry the VERDICT with it — see its doc. Without this the app relearned
  // from zero on every cold start, and learning needs 20 observations above
  // 18 km/h on a fix better than 8 m.
  final saved = repo.load();
  if (saved != null) {
    cal.restore(offsetDeg: saved.offsetDeg, samples: saved.samples);
  }

  // Written on the transition INTO learned rather than on every observation:
  // one Hive write per session instead of one per fix, and an unlearned offset
  // is not worth keeping anyway.
  var wasLearned = cal.isLearned;

  // Fold in pairs as they arrive. `listen`, not `watch`: this provider must
  // keep its learned state rather than being rebuilt on every fix.
  ref.listen(gpsStateProvider, (_, next) {
    final gps = next.valueOrNull;
    if (gps == null) return;
    final mag = ref.read(magneticHeadingProvider).valueOrNull;
    if (mag == null) return;
    if (!cal.observe(
      gpsCourseDeg: gps.headingDeg,
      magneticDeg: mag,
      speedMps: gps.smoothedSpeedMps,
      accuracyM: gps.accuracyM,
    )) {
      return;
    }

    final learned = cal.isLearned;
    if (learned && !wasLearned) repo.save(cal);
    wasLearned = learned;
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
  // Read BEFORE any early return, and deliberately not where it is used.
  //
  // A Provider is created lazily on first read, and [headingCalibrationProvider]
  // only starts listening for (course, magnetic) pairs once it exists. Both
  // reads of it used to sit behind guards — below the `isFinite` return and
  // below the true-north check — and the first of those is the fatal one: while
  // the car is MOVING the GPS course is finite, so the display never reached
  // the magnetic branch, so the provider was never created. Moving is the only
  // time it can learn anything, so it learnt nothing.
  //
  // Silent, and it read as its own opposite: the cluster said MAG, which looks
  // like "still learning" and actually meant "not learning". A driver with the
  // switch off (the default) never created it at all, so turning true north on
  // after an hour of driving started from zero.
  //
  // `HeadingDisplay` watches this provider from app start and neither provider
  // is autoDispose, so this single read keeps the listener alive for the
  // session.
  final calibration = ref.watch(headingCalibrationProvider);

  final gpsHeading = ref.watch(headingProvider); // NaN when stopped
  if (gpsHeading.isFinite) return gpsHeading;

  final mag = ref.watch(magneticHeadingProvider).valueOrNull;
  if (mag == null) return double.nan;

  final wantsTrue = ref.watch(settingsProvider.select((s) => s.useTrueNorth));
  if (!wantsTrue) return mag;
  return calibration.toTrue(mag);
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
