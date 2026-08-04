import 'dart:async';

import '../../distance/domain/motion_repository.dart';
import '../../distance/domain/motion_sample.dart';
import '../../gps/domain/gps_repository.dart';
import '../../gps/domain/gps_sample.dart';

/// A drive that plays into the LIVE app, so a tunnel can be watched happening
/// rather than only asserted about (SPEC-v2 §20.1, the debug-menu option).
///
/// The headless [TracePlayer] answers "did the engine measure the right
/// distance". It cannot answer "does the cluster look right while it happens" —
/// whether the digits go amber at the right moment, whether the EST badge
/// clears without a visible jump, whether the top bar survives the longer
/// status text. Those are questions about the running app, and until this
/// existed the only way to ask them was to drive somewhere with a tunnel.
///
/// ## Why this synthesises rather than reading a fixture file
///
/// The `test/fixtures/*.jsonl` traces are test data. Bundling them as Flutter
/// assets would ship them inside the release APK, so the same profile is
/// generated here instead — a few lines of arithmetic against no assets at all.
/// It mirrors `tunnel_varying.jsonl`, which is the fixture that exercises
/// §12.2's refinement rather than only §12.1's coast.
///
/// Emission is in WALL-CLOCK time, unlike the headless player which runs as
/// fast as it can. Watching it is the entire point.
class SimulatedDrive {
  /// **The Niayesh Tunnel, Tehran** — 6 658 m, the longest urban tunnel in the
  /// Middle East, driven west→east at 60 km/h.
  ///
  /// Real coordinates on a real corridor (Niayesh Highway to Sadr Highway,
  /// north Tehran) so the map shows the car entering one portal and leaving the
  /// other. The portals are corridor endpoints derived from the published
  /// length and route, **not surveyed positions** — the length and the transit
  /// time are exact, the pin is approximate to a few hundred metres.
  ///
  /// This tunnel is the reason `[3.13]` exists: at 60 km/h it takes **399.5 s**,
  /// and `maxTunnelDuration` used to be a flat 300 s, so the app would have
  /// called it a suspended process and silently refused to reconcile it.
  ///
  /// The blackout here is **real silence with location services still enabled**,
  /// which is what a tunnel actually is. Cutting Android's location services
  /// instead is a different scenario entirely (the user switching GPS off) and
  /// conflating the two sent an earlier round of testing chasing the wrong bug.
  static const double lat = 35.7745;
  static const double westPortalLon = 51.3860;
  static const double eastPortalLon = 51.459718;
  static const double tunnelMetres = 6658.0;

  /// Metres per degree of longitude at [lat].
  static const double _mPerDegLon = 90316.6;

  static const double speedMps = 60 / 3.6; // 60 km/h

  /// 60 s on the approach, the tunnel, then 60 s out the far side.
  static const double approachS = 60;
  static double get tunnelS => tunnelMetres / speedMps; // 399.5
  static const double exitS = 60;
  static double get totalS => approachS + tunnelS + exitS;

  /// Distance travelled by time [t], in metres from the start of the approach.
  static double distanceAt(double t) => speedMps * t.clamp(0, totalS);

  /// True while the car is between the portals — GPS emits NOTHING here.
  static bool isDark(double t) => t > approachS && t < approachS + tunnelS;

  /// Longitude at time [t]. The car starts [approachS] worth of driving west of
  /// the west portal and ends [exitS] east of the east portal.
  static double lonAt(double t) {
    final metresFromWestPortal = distanceAt(t) - speedMps * approachS;
    return westPortalLon + metresFromWestPortal / _mPerDegLon;
  }

  /// Constant speed: the accelerometer contributes nothing, so this exercises
  /// §12.1's coast-at-v0 model — the conservative case. The varying-speed case
  /// that exercises §12.2 lives in `tunnel_varying.jsonl`.
  static double accelAt(double t) => 0.0;

  static double speedAt(double t) => speedMps;

}

/// Feeds [SimulatedDrive] fixes in place of the receiver. Emits NOTHING through
/// the blackout — a tunnel is the absence of fixes, and anything else would let
/// the engine off the hook it is being tested on.
class SimulatedGpsRepository implements GpsRepository {
  SimulatedGpsRepository({this.loop = true});

  /// Restart at the end, so the tunnel can be watched more than once without
  /// digging back into the settings screen.
  final bool loop;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<GpsSample?> lastKnown() async => null;

  @override
  Stream<GpsSample> positionStream() async* {
    do {
      // 1 Hz, matching what §19 row 6 baselines.
      for (var s = 0; s <= SimulatedDrive.totalS; s++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        final t = s.toDouble();
        if (SimulatedDrive.isDark(t)) continue;
        yield GpsSample(
          timestamp: DateTime.now(),
          latitude: SimulatedDrive.lat,
          longitude: SimulatedDrive.lonAt(t),
          speedMps: SimulatedDrive.speedAt(t),
          speedAccuracyMps: 0.5,
          headingDeg: 90, // due east, along the corridor
          accuracyM: 5,
          altitudeM: 1200,
          hasFix: true,
        );
      }
    } while (loop);
  }
}

/// The matching inertial stream. Runs THROUGH the blackout — it is the only
/// input the engine has in there, and without it §12.2 cannot refine anything.
class SimulatedMotionRepository implements MotionRepository {
  SimulatedMotionRepository({this.loop = true});

  final bool loop;

  @override
  Stream<MotionSample> motionStream() async* {
    do {
      // 20 Hz, matching the fixture.
      for (var ms = 0; ms <= SimulatedDrive.totalS.toInt() * 1000; ms += 50) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        yield MotionSample(
          timestamp: DateTime.now(),
          userAccel: Vec3(SimulatedDrive.accelAt(ms / 1000.0), 0, 0),
          gravity: const Vec3(0, 0, -9.81),
          gyro: Vec3.zero,
        );
      }
    } while (loop);
  }
}
