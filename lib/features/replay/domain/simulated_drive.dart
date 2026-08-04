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
  /// Metres north of the origin, and the speed, at [t] seconds.
  ///
  /// Piecewise-constant acceleration, integrated in closed form — the same
  /// profile and the same exactness as the committed fixture.
  ///
  ///   0–30 s   GPS on    15 → 25 m/s
  ///   30–110 s DARK      25 → 20 → 25 m/s
  ///   110–140s GPS on    25 m/s
  static const List<List<double>> _segments = [
    [30, 15.0, 1.0 / 3.0],
    [20, 25.0, -0.25],
    [40, 20.0, 0.0],
    [20, 20.0, 0.25],
    [30, 25.0, 0.0],
  ];

  static const double darkFromS = 30;
  static const double darkToS = 110;
  static const double totalS = 140;

  /// Tehran, which is where this ships.
  static const double startLat = 35.6892;
  static const double startLon = 51.3890;
  static const double _degPerMetre = 8.993216059187306e-6;

  static double distanceAt(double t) {
    var d = 0.0, elapsed = 0.0;
    for (final s in _segments) {
      if (t <= elapsed) break;
      final dt = (t - elapsed) < s[0] ? (t - elapsed) : s[0];
      d += s[1] * dt + 0.5 * s[2] * dt * dt;
      elapsed += s[0];
    }
    return d;
  }

  static double speedAt(double t) {
    var elapsed = 0.0;
    for (final s in _segments) {
      if (t < elapsed + s[0]) return s[1] + s[2] * (t - elapsed);
      elapsed += s[0];
    }
    return _segments.last[1];
  }

  static double accelAt(double t) {
    var elapsed = 0.0;
    for (final s in _segments) {
      if (t < elapsed + s[0]) return s[2];
      elapsed += s[0];
    }
    return 0.0;
  }

  /// True while the simulated vehicle is inside the blackout.
  static bool isDark(double t) => t > darkFromS && t < darkToS;

  static double latAt(double t) => startLat + distanceAt(t) * _degPerMetre;
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
          latitude: SimulatedDrive.latAt(t),
          longitude: SimulatedDrive.startLon,
          speedMps: SimulatedDrive.speedAt(t),
          speedAccuracyMps: 0.5,
          headingDeg: 0,
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
      for (var ms = 0; ms <= SimulatedDrive.totalS * 1000; ms += 50) {
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
