import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/constants/app_constants.dart';
import '../domain/gps_repository.dart';
import '../domain/gps_sample.dart';
import '../domain/gps_stall_detector.dart';

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

    // Self-healing subscription loop.
    //
    // ## Silence is NOT failure — a tunnel is silence
    //
    // This is the most important behaviour in the app and it is easy to get
    // backwards. A position stream can fail in three different ways and only
    // two of them justify touching the subscription:
    //
    //   1. it ERRORS            -> re-subscribe (foreground service refused, etc.)
    //   2. it COMPLETES         -> re-subscribe
    //   3. it goes QUIET        -> USUALLY A TUNNEL. Leave it alone.
    //
    // Case 3 has a genuine failure hiding inside it, found on device by driving
    // the real Niayesh corridor: after location services were switched off and
    // back on, the stream stayed subscribed and permanently silent, so the app
    // sat in Estimation Mode with a frozen trip counter and a red EST? badge
    // until it was restarted. On a rally that is the worst failure this app has.
    //
    // The first fix for it was a flat `.timeout()`, and it was WORSE than the
    // bug: it tore the stream down every 20 s, and on device each teardown
    // logged `Stopping location service` / `Start service in foreground mode` —
    // about twenty restarts of the foreground service inside one 400 s tunnel.
    // That service is what keeps the receiver alive in a tunnel in the first
    // place.
    //
    // So the watchdog now needs EVIDENCE that the stream is dead, not merely
    // evidence that it is quiet:
    //
    //   * location services were seen DISABLED and are now ENABLED -> dead,
    //     re-subscribe (this is exactly the observed failure), or
    //   * silence past `gpsSilenceHardLimit`, which is longer than any real
    //     tunnel transit -> re-subscribe once as a backstop.
    //
    // In an ordinary tunnel neither fires, so the subscription and the
    // foreground service are never touched.
    var background = true;
    final stall = GpsStallDetector();
    var servicesEnabled = true;

    while (true) {
      try {
        stall.reset();

        yield* Geolocator.getPositionStream(
          locationSettings: buildSettings(background: background),
        ).map((p) {
          stall.onData();
          return _toSample(p);
        }).timeout(
          AppConstants.gpsSilenceCheck,
          // Providing onTimeout means the stream KEEPS RUNNING. Nothing is torn
          // down unless we deliberately push an error into the sink — which is
          // what makes an ordinary tunnel free of side effects.
          onTimeout: (sink) {
            // Refresh the service state for the NEXT tick to judge on.
            // `onTimeout` is synchronous and this probe is not; being one
            // heartbeat late to notice a toggle is irrelevant against a 20 s
            // cadence, and it keeps the decision itself pure and tested.
            unawaited(Geolocator.isLocationServiceEnabled()
                .then((v) => servicesEnabled = v)
                .catchError((_) => servicesEnabled));

            if (stall.onSilentTick(servicesEnabled: servicesEnabled)) {
              sink.addError(StateError(
                  'position stream stalled (${stall.silentFor.inSeconds}s '
                  'silent, servicesToggled=${stall.sawServicesDisabled})'));
              return;
            }

            // The ordinary tunnel path. Tell consumers there is a gap so the
            // status bar can react instead of holding a stale value, and leave
            // the subscription completely alone.
            sink.add(GpsSample.noFix());
          },
        );
        // Stream completed normally (rare) — fall through and reconnect.
      } catch (e) {
        // The foreground service can fail to start on Android 13+ when the
        // POST_NOTIFICATIONS permission is denied. Drop the FGS requirement for
        // subsequent reconnects so the dashboard keeps working foreground-only.
        //
        // A stall raised by the watchdog above is NOT a foreground-service
        // problem, so it must not cost us the service — otherwise recovering
        // from a toggled location setting would quietly disable background
        // tracking for the rest of the drive.
        final stalled = e is StateError;
        // ignore: avoid_print
        print('iRallyMeter: GPS stream ${stalled ? 'stalled' : 'error'} ($e) — '
            're-subscribing${!stalled && background ? ' (foreground-only fallback)' : ''}…');
        if (!stalled) background = false;
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
