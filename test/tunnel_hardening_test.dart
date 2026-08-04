import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/core/constants/app_constants.dart';
import 'package:irallymeter/features/distance/domain/distance_delta.dart';
import 'package:irallymeter/features/distance/domain/distance_engine.dart';
import 'package:irallymeter/features/distance/domain/distance_engine_state.dart';
import 'package:irallymeter/features/distance/domain/motion_sample.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';
import 'package:irallymeter/features/gps/domain/gps_stall_detector.dart';

/// THE TUNNEL, HARDENED.
///
/// "Does the rally monitor stay on and catch everything while the car is in a
/// tunnel?" — this file exists to answer that in as many shapes as I can think
/// of. Every test here is a way a tunnel can differ from the tidy one in the
/// fixtures, and the bar is the same for all of them: **the engine must not
/// crash, must not stall, must not run the counters backwards, and must not
/// invent distance.**
const double degPerM = 8.993216059187306e-6;

class Rig {
  Rig() {
    engine = DistanceEngine(
      onDelta: deltas.add,
      onState: (s) => state = s,
      onSection: sections.add,
    );
  }

  late final DistanceEngine engine;
  DistanceEngineState state = DistanceEngineState.initial;
  final List<DistanceDelta> deltas = [];
  final List<Object> sections = [];

  DateTime at(int ms) => DateTime.utc(2026).add(Duration(milliseconds: ms));

  double get total =>
      deltas.fold(0.0, (a, d) => a + (d.meters.isFinite ? d.meters : 0));

  void gps({
    required int ms,
    required double northM,
    double speed = 20,
    double accuracy = 5,
    bool hasFix = true,
  }) =>
      engine.onGpsSample(
        GpsSample(
          timestamp: at(ms),
          latitude: 35.7 + northM * degPerM,
          longitude: 51.4,
          speedMps: speed,
          speedAccuracyMps: 0.5,
          headingDeg: 0,
          accuracyM: accuracy,
          altitudeM: 1200,
          hasFix: hasFix,
        ),
        at(ms),
      );

  void motion(int ms, {double ax = 0}) => engine.onMotionSample(
        MotionSample(
          timestamp: at(ms),
          userAccel: Vec3(ax, 0, 0),
          gravity: const Vec3(0, 0, -9.81),
          gyro: Vec3.zero,
        ),
        at(ms),
      );

  void tick(int ms) => engine.tick(at(ms));

  /// Clean approach at [speed], leaving the car [seconds] in.
  void approach({int seconds = 20, double speed = 20}) {
    for (var s = 0; s <= seconds; s++) {
      motion(s * 1000);
      gps(ms: s * 1000, northM: s * speed, speed: speed);
    }
  }

  /// Run the blackout, ticking the heartbeat and optionally feeding motion.
  void blackout({
    required int fromS,
    required int toS,
    bool withMotion = true,
    double ax = 0,
  }) {
    for (var s = fromS; s <= toS; s++) {
      for (var k = 0; k < 4; k++) {
        if (withMotion) motion(s * 1000 + k * 250, ax: ax);
      }
      tick(s * 1000);
    }
  }

  /// Confirm recovery with three consistent fixes.
  void recover({required int fromS, required double northM, double speed = 20}) {
    for (var i = 0; i < 3; i++) {
      motion((fromS + i) * 1000);
      gps(
        ms: (fromS + i) * 1000,
        northM: northM + i * speed,
        speed: speed,
      );
    }
  }

  /// Everything the engine must never do, checked in one place.
  void assertSane({String because = ''}) {
    for (final d in deltas) {
      expect(d.meters.isFinite, isTrue, reason: 'NaN/Inf distance $because');
      expect(d.meters, greaterThanOrEqualTo(0),
          reason: 'negative increment $because');
      expect(d.speedMps.isFinite, isTrue, reason: 'NaN speed $because');
    }
    expect(state.tunnelMeters.isFinite, isTrue, reason: because);
    expect(total.isFinite, isTrue, reason: because);
  }
}

void main() {
  group('A · the tunnel actually works, in many shapes', () {
    test('01 · a short 30 s tunnel', () {
      final r = Rig()..approach();
      r.blackout(fromS: 21, toS: 50);
      expect(r.state.tunnelMode, isTrue);
      r.recover(fromS: 51, northM: 21 * 20 + 30 * 20);
      expect(r.state.tunnelMode, isFalse);
      r.assertSane(because: '(30 s tunnel)');
    });

    test('02 · a 400 s tunnel — Niayesh at 60 km/h', () {
      final r = Rig()..approach(speed: 16.67);
      r.blackout(fromS: 21, toS: 420);
      expect(r.state.tunnelMode, isTrue,
          reason: 'must still be estimating after nearly seven minutes');
      r.recover(fromS: 421, northM: 21 * 16.67 + 400 * 16.67, speed: 16.67);
      expect(r.state.tunnelMode, isFalse);
      r.assertSane(because: '(Niayesh-length)');
    });

    test('03 · a 20 minute tunnel does not break anything', () {
      final r = Rig()..approach();
      r.blackout(fromS: 21, toS: 1220);
      expect(r.state.tunnelMode, isTrue);
      r.assertSane(because: '(20 min)');
      expect(r.state.tunnelMeters, greaterThan(0),
          reason: 'the estimate must keep running, not freeze');
    });

    test('04 · back-to-back tunnels with one second of daylight between', () {
      // Gallery sections on mountain roads do exactly this.
      final r = Rig()..approach();
      var s = 21;
      var m = 21 * 20.0;
      for (var i = 0; i < 6; i++) {
        r.blackout(fromS: s, toS: s + 25);
        m += 25 * 20.0;
        s += 26;
        r.recover(fromS: s, northM: m);
        m += 3 * 20.0;
        s += 3;
      }
      r.assertSane(because: '(6 galleries)');
      expect(r.state.tunnelMode, isFalse);
    });

    test('05 · the car STOPS inside the tunnel (traffic jam) and moves off', () {
      final r = Rig()..approach();
      // Decelerate hard to a standstill, sit, then pull away.
      r.blackout(fromS: 21, toS: 30, ax: -2.0);
      final afterBraking = r.state.tunnelMeters;
      r.blackout(fromS: 31, toS: 120); // stopped, no acceleration
      final afterSitting = r.state.tunnelMeters;
      expect(afterSitting, greaterThanOrEqualTo(afterBraking));
      r.blackout(fromS: 121, toS: 140, ax: 1.5);
      r.assertSane(because: '(jam inside a tunnel)');
      expect(r.state.tunnelMode, isTrue);
    });

    test('06 · entering a tunnel from a standstill invents nothing', () {
      // Waved into a tunnel from a stop line: v0 is genuinely zero.
      final r = Rig();
      for (var s = 0; s <= 20; s++) {
        r.motion(s * 1000);
        r.gps(ms: s * 1000, northM: 0, speed: 0);
      }
      r.blackout(fromS: 21, toS: 120);
      expect(r.state.tunnelMeters, lessThan(5.0),
          reason: 'a stationary car that loses signal must not accumulate — it '
              'held ${r.state.tunnelMeters.toStringAsFixed(1)} m');
      r.assertSane(because: '(entered stopped)');
    });
  });

  group('B · the messy parts of a real portal', () {
    test('07 · a burst of garbage fixes at the mouth does not end the tunnel',
        () {
      final r = Rig()..approach();
      r.blackout(fromS: 21, toS: 80);
      // Re-acquisition noise: wild positions, poor accuracy.
      for (var i = 0; i < 6; i++) {
        r.gps(ms: (81 + i) * 1000, northM: 5000.0 + i * 900, accuracy: 35);
      }
      expect(r.state.tunnelMode, isTrue,
          reason: 'a 35 m fix is not the 20 m §15.2 demands, and a 900 m/s '
              'implied speed is not driving');
      r.assertSane(because: '(portal garbage)');
    });

    test('08 · a single good fix mid-tunnel (a light well) does not end it',
        () {
      final r = Rig()..approach();
      r.blackout(fromS: 21, toS: 60);
      r.gps(ms: 61 * 1000, northM: 21 * 20 + 40 * 20, accuracy: 5);
      expect(r.state.tunnelMode, isTrue,
          reason: '§15.2 wants THREE consecutive fixes; one gap in the roof '
              'must not flip the display');
      r.blackout(fromS: 62, toS: 100);
      r.assertSane(because: '(light well)');
    });

    test('09 · two good fixes then silence again — still estimating', () {
      final r = Rig()..approach();
      r.blackout(fromS: 21, toS: 60);
      r.gps(ms: 61 * 1000, northM: 1220, accuracy: 5);
      r.gps(ms: 62 * 1000, northM: 1240, accuracy: 5);
      expect(r.state.tunnelMode, isTrue);
      r.blackout(fromS: 63, toS: 90);
      expect(r.state.tunnelMode, isTrue);
      r.assertSane(because: '(two-fix tease)');
    });

    test('10 · flapping at the very edge of coverage never oscillates wildly',
        () {
      final r = Rig()..approach();
      var entries = 0;
      var wasTunnel = false;
      for (var cycle = 0; cycle < 10; cycle++) {
        final base = 21 + cycle * 12;
        r.blackout(fromS: base, toS: base + 6);
        if (r.state.tunnelMode && !wasTunnel) entries++;
        wasTunnel = r.state.tunnelMode;
        for (var i = 0; i < 3; i++) {
          r.gps(
            ms: (base + 7 + i) * 1000,
            northM: (21 + cycle * 12) * 20.0 + i * 20,
            accuracy: 5,
          );
        }
        wasTunnel = r.state.tunnelMode;
      }
      r.assertSane(because: '(edge flapping)');
      expect(entries, lessThanOrEqualTo(10),
          reason: 'one entry per genuine dropout at most');
    });
  });

  group('C · the ways a tunnel can go wrong and must not corrupt the trip', () {
    test('11 · the counters never move backwards, in any of these', () {
      final r = Rig()..approach();
      r.blackout(fromS: 21, toS: 120);
      // Recover SHORT of where the estimate thinks we are: the estimate
      // overshot. §16 must not claw it back.
      r.recover(fromS: 121, northM: 21 * 20 + 50 * 20);
      for (var s = 124; s < 200; s++) {
        r.tick(s * 1000);
      }
      var running = 0.0;
      for (final d in r.deltas) {
        running += d.meters;
        expect(d.meters, greaterThanOrEqualTo(0));
      }
      expect(running, greaterThan(0));
      r.assertSane(because: '(overshoot recovery)');
    });

    test('12 · a teleport on exit is rejected, not reconciled', () {
      final r = Rig()..approach();
      r.blackout(fromS: 21, toS: 60);
      // 500 km away: a bad almanac, not a tunnel exit.
      r.recover(fromS: 61, northM: 500000);
      final section = r.engine.sections.last;
      expect(section?.correctionMeters ?? 0, 0,
          reason: 'reconciling a teleport would dump 500 km on the odometer');
      r.assertSane(because: '(teleport)');
    });

    test('13 · NaN and infinite sensor input cannot poison the estimate', () {
      final r = Rig()..approach();
      for (var s = 21; s <= 60; s++) {
        r.engine.onMotionSample(
          MotionSample(
            timestamp: r.at(s * 1000),
            userAccel: Vec3(double.nan, double.infinity, 0),
            gravity: const Vec3(0, 0, -9.81),
            gyro: Vec3(double.nan, 0, 0),
          ),
          r.at(s * 1000),
        );
        r.tick(s * 1000);
      }
      r.assertSane(because: '(NaN motion)');
    });

    test('14 · a NaN GPS speed on the approach still anchors sanely', () {
      final r = Rig();
      for (var s = 0; s <= 20; s++) {
        r.motion(s * 1000);
        r.gps(ms: s * 1000, northM: s * 20.0, speed: double.nan);
      }
      r.blackout(fromS: 21, toS: 80);
      r.assertSane(because: '(NaN Doppler)');
      expect(r.state.tunnelMeters.isFinite, isTrue);
    });

    test('15 · time going backwards mid-tunnel does not break the engine', () {
      final r = Rig()..approach();
      r.blackout(fromS: 21, toS: 60);
      // A clock correction (NTP, timezone) lands mid-tunnel.
      r.tick(30 * 1000);
      r.motion(30 * 1000);
      r.blackout(fromS: 61, toS: 90);
      r.assertSane(because: '(clock went backwards)');
    });

    test('16 · a no-fix sample (the watchdog heartbeat) is inert', () {
      // The GPS service emits GpsSample.noFix() every 20 s of silence so the UI
      // can show the gap. It must not disturb the estimate.
      final r = Rig()..approach();
      final before = r.state.tunnelMeters;
      for (var s = 21; s <= 100; s++) {
        if (s % 20 == 0) {
          r.engine.onGpsSample(GpsSample.noFix(), r.at(s * 1000));
        }
        r.motion(s * 1000);
        r.tick(s * 1000);
      }
      expect(r.state.tunnelMode, isTrue,
          reason: 'a synthetic no-fix must never look like recovery');
      expect(r.state.tunnelMeters, greaterThanOrEqualTo(before));
      r.assertSane(because: '(noFix heartbeat)');
    });
  });

  group('D · the stall detector — tunnel vs dead subscription', () {
    test('17 · quiet with services up is a TUNNEL, never a resubscribe', () {
      final d = GpsStallDetector();
      // Nine minutes of silence, inside the hard limit.
      for (var i = 0; i < 27; i++) {
        expect(d.onSilentTick(servicesEnabled: true), isFalse,
            reason: 'tick $i tore down the subscription inside a tunnel');
      }
    });

    test('18 · a Niayesh transit causes ZERO teardowns', () {
      final d = GpsStallDetector();
      const ticks = 399 ~/ 20;
      for (var i = 0; i < ticks; i++) {
        expect(d.onSilentTick(servicesEnabled: true), isFalse);
      }
    });

    test('19 · services OFF then ON is a dead subscription — resubscribe', () {
      final d = GpsStallDetector();
      expect(d.onSilentTick(servicesEnabled: true), isFalse);
      expect(d.onSilentTick(servicesEnabled: false), isFalse,
          reason: 'nothing to resubscribe to while the service is down');
      expect(d.sawServicesDisabled, isTrue);
      expect(d.onSilentTick(servicesEnabled: true), isTrue,
          reason: 'the OFF -> ON transition is the observed failure');
    });

    test('20 · the hard limit eventually fires even with services up', () {
      final d = GpsStallDetector();
      final ticks =
          AppConstants.gpsSilenceHardLimit.inSeconds ~/
              AppConstants.gpsSilenceCheck.inSeconds;
      for (var i = 0; i < ticks - 1; i++) {
        expect(d.onSilentTick(servicesEnabled: true), isFalse);
      }
      expect(d.onSilentTick(servicesEnabled: true), isTrue);
    });

    test('21 · the hard limit is longer than any real tunnel transit', () {
      double seconds(double m, double kmh) => m / (kmh / 3.6);
      expect(AppConstants.gpsSilenceHardLimit.inSeconds,
          greaterThan(seconds(6658, 60)),
          reason: 'Niayesh, Tehran');
      expect(AppConstants.gpsSilenceHardLimit.inSeconds,
          greaterThan(seconds(6400, 60)),
          reason: 'Alborz, Tehran');
    });

    test('22 · a fix arriving clears everything', () {
      final d = GpsStallDetector();
      d.onSilentTick(servicesEnabled: false);
      expect(d.sawServicesDisabled, isTrue);
      d.onData();
      expect(d.sawServicesDisabled, isFalse);
      expect(d.silentTicks, 0);
      expect(d.onSilentTick(servicesEnabled: true), isFalse,
          reason: 'a recovered stream starts its judgement afresh');
    });
  });
}
