import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/geo_math.dart';
import '../../data/geolocator_gps_service.dart';
import '../../domain/gps_repository.dart';
import '../../domain/gps_sample.dart';
import '../../domain/gps_health_stats.dart';
import '../../domain/gps_state.dart';
import '../../../replay/domain/simulated_drive.dart';
import '../../../replay/presentation/simulation_provider.dart';

/// DI seam: swap for a mock/replay repository in tests or simulation mode.
///
/// SPEC-v2 §20.1's debug-menu option is exactly this seam being used: when
/// simulation is on, the whole app is fed a synthesised drive with a real
/// blackout in it, so a tunnel can be WATCHED rather than only asserted about.
/// Guarded by `kDebugMode` inside [simulationActiveRef] — the release compiler
/// drops the simulated source rather than merely hiding the switch.
final gpsRepositoryProvider = Provider<GpsRepository>((ref) {
  if (simulationActiveRef(ref)) return SimulatedGpsRepository();
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

/// Live §19 row 6 / stream-health measurement, folded from the raw stream.
///
/// Exists so a road test reports NUMBERS rather than impressions: "unmeasured"
/// was never the same as "unmeasurable".
/// NOTE: fed from [gpsStateProvider], not by listening here. A Provider is
/// created lazily on first read, so a listener declared inside this body would
/// only start recording when someone OPENED the diagnostics screen — which is
/// exactly the wrong time. `gpsStateProvider` is alive for as long as the
/// dashboard is, so the stats cover the whole session.
final gpsHealthProvider = Provider<GpsHealthStats>((ref) => GpsHealthStats());

/// The active stream failure, or null when the receiver is merely quiet.
///
/// Separate from the dropout watchdog on purpose: a tunnel is silence and must
/// keep reading GPS LOST, while a revoked permission or a dead sensor is a
/// fault the crew can act on.
final gpsStreamErrorProvider = Provider<String?>((ref) =>
    ref.watch(gpsStateProvider).valueOrNull?.streamError);

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
  // Which source the heading is currently coming from. Latched deliberately,
  // with a hysteresis band — see the switch below.
  bool usingGpsCourse = false;
  String? lastError;
  GpsSample? prev;
  final controller = StreamController<GpsState>();

  final health = ref.read(gpsHealthProvider);
  ref.listen<AsyncValue<GpsSample>>(rawGpsStreamProvider, (_, next) {
    if (controller.isClosed) return;

    // A FAILED stream is not the same as a quiet one, and this used to treat
    // them identically: `next.valueOrNull` turns an AsyncError into null, so a
    // revoked permission, a dead sensor and a platform exception were all
    // silently skipped and the cluster went on showing its last good value
    // until the dropout watchdog eventually said GPS LOST. The driver could
    // not tell a broken receiver from a tunnel.
    //
    // The service retries internally, so what reaches here is a failure that
    // survived that — worth surfacing rather than swallowing.
    if (next.hasError) {
      lastError = next.error.toString();
      controller.add(GpsState.initial().copyWithError(lastError));
      return;
    }

    final s = next.valueOrNull;
    if (s == null) return;
    // A fix arrived: whatever was wrong is over.
    lastError = null;
    // §19 row 6 / stream-health measurement for the road test.
    health.add(s, DateTime.now());

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

    // Heading source, with hysteresis.
    //
    // This used to be a single `if` with no `else`, which made it a ONE-WAY
    // LATCH rather than the hybrid it is documented as: `smoothedHeading` was
    // only ever assigned, so after the first moving fix it stayed finite for
    // the life of the app and `capHeadingProvider` could never fall through to
    // the magnetometer. Standing still, the cluster showed a stale frozen
    // course still labelled GPS — a heading it could not know, asserted as
    // current.
    //
    // Releasing on a single threshold would have swapped that for the opposite
    // fault: a car crawling in traffic sits on the boundary and the source
    // flips every fix. Hence a band — acquire high, release low, hold in
    // between.
    if (speed >= AppConstants.headingGpsAcquireMps) {
      usingGpsCourse = true;
    } else if (speed <= AppConstants.headingGpsReleaseMps) {
      usingGpsCourse = false;
    }

    if (usingGpsCourse) {
      // A moving fix with no course reported holds the last good one rather
      // than dropping the needle; only leaving the band releases.
      if (s.headingDeg.isFinite) {
        smoothedHeading = smoothedHeading.isNaN
            ? s.headingDeg
            : GeoMath.smoothAngle(
                smoothedHeading, s.headingDeg, AppConstants.headingSmoothing);
      }
    } else {
      // NaN is the signal `capHeadingProvider` reads to switch to the
      // magnetometer, and it also means the next acquisition adopts the new
      // course outright instead of smoothing up from a pre-stop bearing.
      smoothedHeading = double.nan;
    }

    controller.add(GpsState(
      streamError: lastError,
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
