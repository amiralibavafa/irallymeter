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

  /// [background] adds the foreground-service config that keeps GPS streaming
  /// when the app is backgrounded / screen off. When false we stream
  /// foreground-only — used as a fallback if the foreground service can't start.
  LocationSettings _settings({required bool background}) {
    return AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: AppConstants.gpsDistanceFilterMeters,
      intervalDuration: AppConstants.gpsInterval,
      forceLocationManager: false,
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
          locationSettings: _settings(background: background),
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
      speedMps: p.speed.isFinite && p.speed >= 0 ? p.speed : 0,
      headingDeg: p.heading.isFinite ? p.heading : double.nan,
      accuracyM: p.accuracy,
      altitudeM: p.altitude,
      hasFix: true,
    );
  }
}
