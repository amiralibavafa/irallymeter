import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/geo_math.dart';
import '../../data/geolocator_gps_service.dart';
import '../../domain/gps_repository.dart';
import '../../domain/gps_sample.dart';
import '../../domain/gps_state.dart';

/// DI seam: swap for a mock/replay repository in tests or simulation mode.
final gpsRepositoryProvider = Provider<GpsRepository>((ref) {
  return GeolocatorGpsService();
});

/// Resolves once: are we permitted to stream location?
final gpsPermissionProvider = FutureProvider<bool>((ref) {
  return ref.watch(gpsRepositoryProvider).ensurePermission();
});

/// Raw, unfiltered fixes straight off the platform. This is the SINGLE source
/// of GPS truth: it is the only provider that subscribes to the native position
/// stream. The trip/route/average integrators listen to THIS, and the smoothed
/// [gpsStateProvider] is derived from it (below) — so exactly one native GPS
/// subscription is open for the whole app, not one per consumer.
final rawGpsStreamProvider = StreamProvider<GpsSample>((ref) {
  return ref.watch(gpsRepositoryProvider).positionStream();
});

/// Processed display state: smoothed speed + heading + quality.
///
/// Derived from [rawGpsStreamProvider] rather than re-subscribing to the
/// platform — this keeps the display, trip integration and dropout watchdog all
/// reading the exact same fix sequence, and halves GPS radio/battery use.
/// Smoothing state lives in closures captured here; fixes arrive in order so the
/// EMA carries correctly. Widgets read individual fields via `.select(...)` to
/// avoid rebuilding the whole dashboard on every tick.
final gpsStateProvider = StreamProvider<GpsState>((ref) {
  final speedFilter = SpeedFilter();
  double smoothedHeading = double.nan;
  GpsSample? prev;
  final controller = StreamController<GpsState>();

  ref.listen<AsyncValue<GpsSample>>(rawGpsStreamProvider, (_, next) {
    final s = next.valueOrNull;
    if (s == null || controller.isClosed) return;

    // Prefer the GPS-reported (Doppler) speed — it's the most accurate. Fall
    // back to position-delta speed when the platform reports none: the Android
    // emulator and some real GPS chips never supply a speed value, so without
    // this the readout would sit at 0 even while moving.
    var rawSpeed = s.speedMps;
    if (rawSpeed <= 0 && prev != null) {
      final dtMs = s.timestamp.difference(prev!.timestamp).inMilliseconds;
      if (dtMs > 0) {
        final meters = GeoMath.distanceMeters(
            prev!.latitude, prev!.longitude, s.latitude, s.longitude);
        final derived = meters / (dtMs / 1000.0);
        // Ignore physically impossible values (e.g. emulator teleports).
        if (derived <= 90.0) rawSpeed = derived;
      }
    }
    prev = s;

    // Pass the fix's own timestamp: SPEC-v2 §19 budgets the display latency
    // in SECONDS, so the filter has to know how much time a sample represents.
    final speed = speedFilter.add(rawSpeed, s.accuracyM, s.timestamp);

    // Only trust GPS course when actually moving; otherwise hold last heading.
    if (s.headingDeg.isFinite && speed > AppConstants.speedNoiseFloorMps) {
      smoothedHeading = smoothedHeading.isNaN
          ? s.headingDeg
          : GeoMath.smoothAngle(
              smoothedHeading, s.headingDeg, AppConstants.headingSmoothing);
    }

    controller.add(GpsState(
      smoothedSpeedMps: speed,
      headingDeg: smoothedHeading,
      accuracyM: s.accuracyM,
      latitude: s.latitude,
      longitude: s.longitude,
      altitudeM: s.altitudeM,
      quality: GpsState.qualityFor(s.accuracyM, s.hasFix),
      receivedAt: DateTime.now(),
      hasFix: s.hasFix,
    ));
  }, fireImmediately: true);

  ref.onDispose(controller.close);
  return controller.stream;
});

/// Convenience slices — widgets watch only what they render.
final speedMpsProvider = Provider<double>((ref) {
  return ref.watch(
    gpsStateProvider.select(
      (v) => v.valueOrNull?.smoothedSpeedMps ?? 0,
    ),
  );
});

final headingProvider = Provider<double>((ref) {
  return ref.watch(
    gpsStateProvider.select((v) => v.valueOrNull?.headingDeg ?? double.nan),
  );
});

final fixQualityProvider = Provider<FixQuality>((ref) {
  return ref.watch(
    gpsStateProvider.select((v) => v.valueOrNull?.quality ?? FixQuality.none),
  );
});

final accuracyProvider = Provider<double>((ref) {
  return ref.watch(
    gpsStateProvider.select((v) => v.valueOrNull?.accuracyM ?? -1),
  );
});

/// 1 Hz watchdog driving the "GPS LOST" warning. Kept on its own low-frequency
/// provider so it doesn't churn the high-frequency display widgets.
///
/// Hysteresis: a fix must be stale for [gpsDropoutConfirmTicks] consecutive
/// ticks before we declare a dropout, so a single skipped/late fix doesn't flap
/// the warning red. Recovery is instant — the first fresh fix clears it.
final gpsDropoutProvider = StreamProvider<bool>((ref) {
  var staleTicks = 0;
  var dropped = true; // Start "lost" until the first fix confirms otherwise.
  return Stream<bool>.periodic(const Duration(seconds: 1), (_) {
    final state = ref.read(gpsStateProvider).valueOrNull;
    final fresh = state != null &&
        state.hasFix &&
        DateTime.now().difference(state.receivedAt) <=
            AppConstants.gpsStaleTimeout;
    if (fresh) {
      staleTicks = 0;
      dropped = false;
    } else if (++staleTicks >= AppConstants.gpsDropoutConfirmTicks) {
      dropped = true;
    }
    return dropped;
  }).distinct();
});
