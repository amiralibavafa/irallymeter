import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/core/constants/app_constants.dart';
import 'package:irallymeter/features/distance/domain/distance_engine.dart';
import 'package:irallymeter/features/distance/domain/distance_engine_state.dart';
import 'package:irallymeter/features/distance/domain/motion_sample.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';

/// Real tunnels, against the sanity bound that was supposed to protect us from
/// a suspended app.
///
/// Found by asking a simple question — "what happens if we drive the app
/// through an actual tunnel in Tehran?" — and doing the arithmetic:
///
///   Niayesh, Tehran    6658 m @ 60 km/h =  399 s
///   Alborz, Tehran     6400 m @ 60 km/h =  384 s
///   Lærdal, Norway    24500 m @ 80 km/h = 1102 s
///
/// `maxTunnelDuration` was a flat **300 s**. So the app would have classified
/// the second-longest urban tunnel in the world — one its own users drive
/// through — as a backgrounded process, and silently declined to reconcile it.
/// The constant's own comment claimed the cap "is not a practical limit on real
/// tunnels" while naming Lærdal, which exceeds it by 3.7x.
///
/// The fix is not a bigger number. Duration was never the right discriminator:
/// **a suspended app stops delivering inertial samples, and a car in a tunnel
/// does not.** These tests hold that distinction.
const double degPerM = 8.993216059187306e-6;

class Rig {
  Rig() {
    engine = DistanceEngine(onDelta: (_) {}, onState: (s) => state = s);
  }

  late final DistanceEngine engine;
  DistanceEngineState state = DistanceEngineState.initial;
  double reconciled = 0;

  DateTime at(int ms) => DateTime.utc(2026).add(Duration(milliseconds: ms));

  void gps({required int ms, required double northM, double speed = 16.67}) =>
      engine.onGpsSample(
        GpsSample(
          timestamp: at(ms),
          latitude: 35.7 + northM * degPerM,
          longitude: 51.4,
          speedMps: speed,
          speedAccuracyMps: 0.5,
          headingDeg: 0,
          accuracyM: 5,
          altitudeM: 1200,
          hasFix: true,
        ),
        at(ms),
      );

  void motion(int ms) => engine.onMotionSample(
        MotionSample(
          timestamp: at(ms),
          userAccel: Vec3.zero,
          gravity: const Vec3(0, 0, -9.81),
          gyro: Vec3.zero,
        ),
        at(ms),
      );

  void tick(int ms) => engine.tick(at(ms));

  /// Drive a tunnel of [seconds] at [speed], with or without the inertial
  /// stream running through it. Returns the metres queued for reconciliation.
  double driveTunnel({
    required int seconds,
    double speed = 16.67,
    bool motionThrough = true,
  }) {
    // Approach with both streams live.
    for (var s = 0; s <= 20; s++) {
      motion(s * 1000);
      gps(ms: s * 1000, northM: s * speed, speed: speed);
    }
    final entryM = 20 * speed;

    // Blackout: no fixes. Motion continues only if the app stayed alive.
    for (var s = 21; s <= 20 + seconds; s++) {
      if (motionThrough) motion(s * 1000);
      tick(s * 1000);
    }

    final exitS = 20 + seconds;
    final exitM = entryM + seconds * speed;
    final before = state.tunnelMeters;

    // Three confirming fixes at the far portal.
    for (var i = 0; i < 3; i++) {
      if (motionThrough) motion((exitS + i) * 1000);
      gps(ms: (exitS + i) * 1000, northM: exitM + i * speed, speed: speed);
    }

    // Pay out whatever was queued and total it.
    var paid = 0.0;
    var last = 0.0;
    for (var s = exitS + 3; s <= exitS + 200; s++) {
      tick(s * 1000);
      last = s.toDouble();
    }
    expect(last, greaterThan(0));
    paid = engine.sections.last?.correctionMeters ?? 0;
    expect(before, greaterThanOrEqualTo(0));
    return paid;
  }
}

void main() {
  group('the cap was wrong for real tunnels', () {
    test('01 · the old flat 5 min cap is shorter than tunnels people drive',
        () {
      // Not a behaviour test — a statement of the arithmetic that motivated the
      // change, pinned so nobody quietly restores the flat cap.
      double seconds(double metres, double kmh) => metres / (kmh / 3.6);
      expect(seconds(6658, 60), greaterThan(300),
          reason: 'Niayesh, Tehran, at 60 km/h');
      expect(seconds(6400, 60), greaterThan(300),
          reason: 'Alborz, Tehran, at 60 km/h');
      expect(seconds(24500, 80), greaterThan(300),
          reason: 'Lærdal — the tunnel the old comment cited as proof the cap '
              'was generous');
      expect(AppConstants.maxTunnelDurationWithMotion.inSeconds,
          greaterThan(seconds(24500, 60)),
          reason: 'the motion-backed cap must clear the longest road tunnel in '
              'the world at a slow 60 km/h');
    });

    test('02 · a Niayesh-length tunnel IS reconciled when motion kept running',
        () {
      // 6658 m at 60 km/h = 399 s, well past the old 300 s cap.
      final paid = Rig().driveTunnel(seconds: 399, motionThrough: true);
      expect(paid, greaterThan(0),
          reason: 'the inertial stream ran the whole way, so the app was '
              'demonstrably alive and this was a tunnel, not a suspension');
    });

    test('03 · a Lærdal-length blackout is reconciled too', () {
      final paid = Rig().driveTunnel(seconds: 1102, motionThrough: true);
      expect(paid, greaterThan(0));
    });
  });

  group('but a suspended app is still refused', () {
    test('04 · the same long blackout with a DEAD motion stream is not '
        'reconciled', () {
      // This is the case the cap exists for: fixes stop, the process is frozen,
      // and on resume the chord is real driving nobody measured. Reconciling it
      // would dump tens of kilometres onto the trip counter.
      final paid = Rig().driveTunnel(seconds: 399, motionThrough: false);
      expect(paid, 0,
          reason: 'no inertial evidence means no proof the app was alive, so '
              'the conservative cap must still apply');
    });

    test('05 · a SHORT blackout with no motion is still reconciled', () {
      // The fallback cap is unchanged at 5 minutes, so short tunnels behave
      // exactly as before even on a device whose sensors are silent.
      final paid = Rig().driveTunnel(seconds: 100, motionThrough: false);
      expect(paid, greaterThan(0),
          reason: 'a 100 s blackout is inside the old cap; nothing about that '
              'case should have changed');
    });

    test('06 · motion that STOPS mid-tunnel revokes the trust', () {
      // The subtle one: the app was alive at the mouth, then got frozen. The
      // engine must notice the stream went quiet rather than riding on the
      // continuity it had at entry.
      final r = Rig();
      const speed = 16.67;
      for (var s = 0; s <= 20; s++) {
        r.motion(s * 1000);
        r.gps(ms: s * 1000, northM: s * speed, speed: speed);
      }
      // 30 s of healthy blackout...
      for (var s = 21; s <= 50; s++) {
        r.motion(s * 1000);
        r.tick(s * 1000);
      }
      // ...then the sensors die for the remaining 370 s.
      for (var s = 51; s <= 420; s++) {
        r.tick(s * 1000);
      }
      final exitM = 20 * speed + 400 * speed;
      for (var i = 0; i < 3; i++) {
        r.gps(ms: (420 + i) * 1000, northM: exitM + i * speed, speed: speed);
      }
      for (var s = 423; s <= 600; s++) {
        r.tick(s * 1000);
      }
      expect(r.engine.sections.last?.correctionMeters ?? 0, 0,
          reason: 'continuity claimed at the mouth must not survive the stream '
              'going silent for six minutes');
    });

    test('07 · entering a tunnel on a device with no sensors claims nothing',
        () {
      // A phone with a broken/absent accelerometer must not inherit trust it
      // never earned.
      final r = Rig();
      const speed = 16.67;
      for (var s = 0; s <= 20; s++) {
        r.gps(ms: s * 1000, northM: s * speed, speed: speed); // no motion ever
      }
      for (var s = 21; s <= 420; s++) {
        r.tick(s * 1000);
      }
      final exitM = 20 * speed + 400 * speed;
      for (var i = 0; i < 3; i++) {
        r.gps(ms: (420 + i) * 1000, northM: exitM + i * speed, speed: speed);
      }
      for (var s = 423; s <= 600; s++) {
        r.tick(s * 1000);
      }
      expect(r.engine.sections.last?.correctionMeters ?? 0, 0);
    });
  });
}
