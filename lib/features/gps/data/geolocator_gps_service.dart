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
  /// The two platform calls the reconnect loop depends on, injectable so the
  /// loop itself can be tested.
  ///
  /// Codex was right that the old loop was untestable, and it was worse than
  /// that: it never worked. `yield*` forwards a stream's error events to the
  /// CONSUMER, it does not throw them into the enclosing `try/catch`, so the
  /// whole retry/downgrade block below was unreachable. Proven with a
  /// standalone Dart program before this rewrite, and now pinned by
  /// `gps_reconnect_test.dart`.
  GeolocatorGpsService({
    Stream<Position> Function(LocationSettings)? positionSource,
    Future<bool> Function()? serviceEnabled,
    Future<Position?> Function({required bool forceAndroidLocationManager})?
        lastKnownSource,
  })  : _positionSource = positionSource ??
            ((s) => Geolocator.getPositionStream(locationSettings: s)),
        _serviceEnabled =
            serviceEnabled ?? Geolocator.isLocationServiceEnabled,
        _lastKnownSource = lastKnownSource ?? Geolocator.getLastKnownPosition;

  final Stream<Position> Function(LocationSettings) _positionSource;
  final Future<bool> Function() _serviceEnabled;

  /// Seam for the cold-start seed fix, so the provider choice is assertable.
  final Future<Position?> Function({required bool forceAndroidLocationManager})
      _lastKnownSource;

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

    /// Consecutive non-stall errors. The foreground service is dropped only on
    /// the SECOND one, because dropping it is not free and is not reversible
    /// within a drive: it is what keeps the receiver alive with the screen off,
    /// which is the whole point of a trip computer on a windscreen mount.
    ///
    /// A device that genuinely cannot start the service — POST_NOTIFICATIONS
    /// denied, the case this fallback exists for — fails every single time, so
    /// it still downgrades, one 1.5 s reconnect later. A one-off platform
    /// hiccup no longer costs the rest of the drive.
    var consecutiveErrors = 0;

    while (true) {
      stall.reset();
      var stalled = false;

      try {
        // `await for`, NOT `yield*`.
        //
        // This is the whole reason the old loop never worked. `yield*` forwards
        // a stream's ERROR EVENTS to the consumer of the generated stream; it
        // does not throw them into the enclosing `try/catch`. So every error
        // path below — the geolocator failure, the watchdog's StateError, the
        // foreground-service downgrade — was unreachable, and a single error
        // ended the stream permanently for the rest of the process. That is the
        // observed Android OFF -> ON failure, and it is also why `[SA-V2 8]`'s
        // two-consecutive-errors rule had no effect: it lived in dead code.
        //
        // `await for` routes the error through this frame, so the retry
        // controller actually runs. Verified with a standalone Dart program,
        // and pinned by `gps_reconnect_test.dart`.
        await for (final sample in _watched(background, stall, () {
          // Data proves this subscription works. Forget earlier failures so a
          // hiccup an hour ago cannot combine with one now into a downgrade.
          consecutiveErrors = 0;
        })) {
          yield sample;
        }
        // Completed normally (rare) — fall through and reconnect.
        //
        // AND SAY SO. This path emitted NOTHING and fell straight into the
        // backoff, so the consumer never learned the subscription had been
        // replaced and the first recovered fix silently reused the pre-outage
        // position, speed and course. It is the quietest of the break paths and
        // was the last one found. Not a stall — there is no evidence the stream
        // was dead, it simply ended.
        yield GpsSample.resubscribed();
      } on _StallSignal catch (e) {
        stalled = true;
        // ignore: avoid_print
        print('iRallyMeter: GPS stream stalled ($e) — re-subscribing…');
        // Marked as a STALL only when there is evidence, which is precisely
        // `sawServicesDisabled` — the services OFF→ON transition. The other way
        // in here is the elapsed-silence backstop, and elapsed silence cannot
        // distinguish a dead subscription from a very long tunnel: no duration
        // can, because a jam inside one outlasts any limit. Counting that as a
        // confirmed stall would put a false fault on the one field
        // `ROAD-TEST.md` item 2 asks the tester to read, which is worse than
        // not counting it — a health number that fires on a normal tunnel is
        // noise, and C2 already cost us one counter nobody could trust.
        //
        // The re-subscribe itself still happens either way; only the CLAIM
        // about what it means is withheld.
        // `resubscribed()`, NOT `noFix()`, for the unevidenced case. Both are
        // no-fix samples and neither is counted as a fault, but a rebuilt
        // subscription invalidates derived state while an ordinary tunnel
        // heartbeat does not — and `noFix()` could not tell them apart.
        yield e.sawServicesDisabled
            ? GpsSample.stalled()
            : GpsSample.resubscribed();
      } catch (e) {
        // The foreground service can fail to start on Android 13+ when the
        // POST_NOTIFICATIONS permission is denied. Drop the FGS requirement for
        // subsequent reconnects so the dashboard keeps working foreground-only.
        //
        // A stall raised by the watchdog is NOT a foreground-service problem,
        // so it must not cost us the service — otherwise recovering from a
        // toggled location setting would quietly disable background tracking
        // for the rest of the drive.
        consecutiveErrors++;
        final downgrade = background && consecutiveErrors >= 2;
        // ignore: avoid_print
        print('iRallyMeter: GPS stream error ($e) — re-subscribing'
            '${downgrade ? ' (foreground-only fallback)' : ''}…');
        if (downgrade) background = false;
        // MARKED, not a plain no-fix. Retrying is right, but the old code
        // yielded the identical value a tunnel produces, so the failure became
        // invisible the moment it was handled: `gpsStateProvider`'s error
        // branch and the GPS ERROR status were unreachable in the shipped app
        // and a revoked permission read as GPS LOST. The crew was sent looking
        // for sky instead of into settings. The stream still never errors.
        yield GpsSample.error('$e');
      }

      // `stalled` is kept for readability at the branch above; the detector and
      // the service-state probe both live in `_watched` and are rebuilt on
      // every reconnect, so a known-bad subscription cannot leak state forward.
      assert(stalled || true);

      await Future<void>.delayed(AppConstants.gpsReconnectBackoff);
    }
  }

  /// One native subscription, wrapped in the silence watchdog.
  ///
  /// Kept separate so the loop above reads as pure retry policy, and so the
  /// watchdog's decision to give up surfaces as a distinct [_StallSignal]
  /// rather than being confused with a platform error — they need opposite
  /// responses to the foreground service.
  Stream<GpsSample> _watched(
    bool background,
    GpsStallDetector stall,
    void Function() onLiveData,
  ) {
    var servicesEnabled = true;
    return _positionSource(buildSettings(background: background)).map((p) {
      stall.onData();
      onLiveData();
      return _toSample(p);
    }).timeout(
      AppConstants.gpsSilenceCheck,
      // Providing onTimeout means the stream KEEPS RUNNING. Nothing is torn
      // down unless we deliberately push an error into the sink — which is what
      // makes an ordinary tunnel free of side effects.
      onTimeout: (sink) {
        // Refresh the service state for the NEXT tick to judge on. `onTimeout`
        // is synchronous and this probe is not; being one heartbeat late to
        // notice a toggle is irrelevant against a 20 s cadence, and it keeps
        // the decision itself pure and tested.
        unawaited(_serviceEnabled()
            .then((v) => servicesEnabled = v)
            .catchError((_) => servicesEnabled));

        if (stall.onSilentTick(servicesEnabled: servicesEnabled)) {
          sink.addError(_StallSignal(stall.silentFor, stall.sawServicesDisabled));
          sink.close();
          return;
        }

        // The ordinary tunnel path. Tell consumers there is a gap so the status
        // bar can react instead of holding a stale value, and leave the
        // subscription completely alone.
        sink.add(GpsSample.noFix());
      },
    );
  }

  @override
  Future<GpsSample?> lastKnown() async {
    // `forceAndroidLocationManager: true` is NOT optional here.
    //
    // It defaults to FALSE, and the plugin's GeolocationManager then returns
    // FusedLocationClient whenever Google Play Services is present. The stream
    // sets `forceLocationManager: true` precisely to avoid the fused
    // provider's road-snapping — but this call bypassed that, so on an
    // ordinary phone the FIRST position the map and speedometer showed came
    // from the one provider the rest of the file deliberately refuses.
    //
    // A seed fix snapped to a road is worse than a slightly stale raw one: it
    // is confidently wrong, and it is the value the trip anchor starts from.
    final pos = await _lastKnownSource(forceAndroidLocationManager: true);
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

/// The watchdog concluding the subscription is dead, as opposed to the platform
/// reporting a failure. Distinct types because the two need opposite responses:
/// a stall must NOT cost the foreground service, a platform error eventually
/// should.
class _StallSignal implements Exception {
  const _StallSignal(this.silentFor, this.sawServicesDisabled);
  final Duration silentFor;
  final bool sawServicesDisabled;

  @override
  String toString() => 'position stream stalled (${silentFor.inSeconds}s '
      'silent, servicesToggled=$sawServicesDisabled)';
}
