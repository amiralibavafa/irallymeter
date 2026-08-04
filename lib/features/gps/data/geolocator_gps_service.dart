import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/constants/app_constants.dart';
import '../domain/gps_repository.dart';
import '../domain/gps_sample.dart';

/// geolocator-backed implementation of [GpsRepository].
///
/// Configured for continuous rally use: highest accuracy, time-based updates
/// (so we get data even when crawling), and an Android foreground service so
/// the GPS keeps streaming when the screen is off / app backgrounded.
class GeolocatorGpsService implements GpsRepository {
  @override
  Future<bool> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return false;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return false;
    }
    return true;
  }

  /// Per-platform receiver configuration (SPEC-v2 §18.2).
  ///
  /// [background] asks for continued updates when the app is not in front. It
  /// is a request, not a guarantee, and the platform can refuse it: Android's
  /// foreground service fails to start when POST_NOTIFICATIONS is denied, and
  /// iOS raises if background updates are enabled without "always" permission.
  /// [positionStream] therefore retries with it false rather than latching into
  /// a permanent GPS-lost state — see the reconnect loop below.
  ///
  /// This returned `AndroidSettings` on EVERY platform until [3.6]. It compiled
  /// and ran, because `AndroidSettings` is a `LocationSettings` and the iOS
  /// plugin reads the fields it recognises off the base class — so the failure
  /// was silent: iOS quietly got default `accuracy`, no `activityType`, no
  /// background updates, and `pauseLocationUpdatesAutomatically` at its default.
  /// The one that actually breaks a rally is that last one: iOS pauses location
  /// updates when it decides the vehicle has stopped, which on a start line is
  /// exactly wrong.
  @visibleForTesting
  LocationSettings buildSettings({required bool background}) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: AppConstants.gpsDistanceFilterMeters,
          // "as a cue to determine when location updates may be automatically
          // paused" — tell iOS this is a car so its heuristics match reality.
          activityType: ActivityType.automotiveNavigation,
          // §18.2: "otherwise iOS will pause updates when it thinks the vehicle
          // has stopped." A rally car sits still at a start line and at a time
          // control; the trip computer must not go to sleep with it.
          pauseLocationUpdatesAutomatically: false,
          allowBackgroundLocationUpdates: background,
          // The blue status bar. Not decoration: it is what iOS shows in place
          // of silently killing a background location session, and hiding it
          // is a review risk on an app that tracks continuously.
          showBackgroundLocationIndicator: background,
        );
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return AndroidSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: AppConstants.gpsDistanceFilterMeters,
          intervalDuration: AppConstants.gpsInterval,
          // SPEC-v2 §18.2: "Fused location applies its own smoothing and road
          // snapping, which is helpful for navigation and wrong for
          // measurement." This instrument's whole job is to report the ground
          // truth it measured, not a plausible position on a known road — a
          // snapped fix silently rewrites the distance we are being paid to
          // measure. Going direct to the LocationManager also drops the Play
          // Services dependency, which matters on the devices this ships to.
          forceLocationManager: true,
          foregroundNotificationConfig: background
              ? const ForegroundNotificationConfig(
                  notificationTitle: 'iRallyMeter tracking',
                  notificationText: 'GPS active — trip & stage timing running',
                  enableWakeLock: true,
                  setOngoing: true,
                )
              : null,
        );
    }
  }

  @override
  Stream<GpsSample> positionStream() async* {
    // Seed instantly with the last known fix so the map/speed aren't blank on a
    // cold start while the first live fix is still being acquired.
    try {
      final seed = await lastKnown();
      if (seed != null) yield seed;
    } catch (_) {
      // A missing/failed seed is non-fatal — the live stream below is the
      // source of truth; just skip the head-start.
    }

    // Self-healing subscription loop. A platform position stream can error or
    // end (GPS toggled, provider hiccup, foreground service refused). Instead of
    // latching into a permanent "GPS LOST" state until the app restarts, we emit
    // a synthetic no-fix sample and re-subscribe after a short backoff.
    var background = true;
    while (true) {
      try {
        yield* Geolocator.getPositionStream(
          locationSettings: buildSettings(background: background),
        ).map(_toSample);
        // Stream completed normally (rare) — fall through and reconnect.
      } catch (e) {
        // The foreground service can fail to start on Android 13+ when the
        // POST_NOTIFICATIONS permission is denied. Drop the FGS requirement for
        // subsequent reconnects so the dashboard keeps working foreground-only;
        // every other error simply triggers a reconnect.
        // ignore: avoid_print
        print('iRallyMeter: GPS stream error ($e) — reconnecting'
            '${background ? ' (foreground-only fallback)' : ''}…');
        background = false;
        // Surface the gap to consumers so the status bar can react instead of
        // holding a frozen last value.
        yield GpsSample.noFix();
      }
      await Future<void>.delayed(AppConstants.gpsReconnectBackoff);
    }
  }

  @override
  Future<GpsSample?> lastKnown() async {
    final pos = await Geolocator.getLastKnownPosition();
    if (pos == null) return null;
    return _toSample(pos);
  }

  GpsSample _toSample(Position p) {
    return GpsSample(
      timestamp: p.timestamp,
      latitude: p.latitude,
      longitude: p.longitude,
      // Raw, including negative and NaN — SPEC-v2 §7.1 needs to SEE an
      // unusable reading in order to fall back to differentiating positions.
      // This previously coerced bad values to 0, which made them
      // indistinguishable from a real standstill and left the fallback dead.
      speedMps: p.speed,
      speedAccuracyMps: p.speedAccuracy,
      headingDeg: p.heading.isFinite ? p.heading : double.nan,
      accuracyM: p.accuracy,
      altitudeM: p.altitude,
      hasFix: true,
    );
  }
}
