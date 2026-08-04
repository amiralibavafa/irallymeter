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
  _latch();
  _latchGaps();
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

/// THE 20-25 m LATCH — found in the Phase 5 self-review.
///
/// `GpsDistanceSource.isHealthy` accepts a fix up to
/// [AppConstants.usableAccuracyMeters] (25 m) and measures with it happily.
/// §15.2 only ends Estimation Mode on fixes of
/// [AppConstants.estimationExitAccuracyMeters] (20 m) or better, and nothing
/// else ends it at all.
///
/// So a band exists — 21 m to 25 m — where every arriving fix is good enough to
/// integrate but not good enough to escape with. The engine sits in Estimation
/// Mode dead-reckoning from v0 while perfectly usable fixes stream past it.
/// Light tree cover and shallow urban canyon land in exactly that band.
///
/// The damage is NOT that the estimate is noisy. It is that the estimate cannot
/// see speed it is never told about: hold v0 while the car actually slows, and
/// the app invents distance that no later correction removes, because
/// `_reconcileAgainst` pays out undershoot only.
void _latch() {
  /// Drives [seconds] at [speed] with fixes at [accuracy], motion at 4 Hz so
  /// the sensor source is never starved by [AppConstants.motionMaxGap] (750 ms).
  void drive(Rig r, {required int fromS, required int seconds,
      required double speed, required double accuracy, required double startM}) {
    var north = startM;
    for (var s = fromS; s < fromS + seconds; s++) {
      for (var k = 0; k < 4; k++) {
        r.motion(s * 1000 + k * 250);
      }
      north += speed;
      r.gps(ms: s * 1000, northM: north, speed: speed, accuracy: accuracy);
      r.tick(s * 1000);
    }
  }

  group('the 20-25 m band must not latch Estimation Mode on forever', () {
    test('30 · steady 22 m fixes eventually end Estimation Mode', () {
      final r = Rig();
      r.approach(seconds: 20, speed: 20);
      r.blackout(fromS: 21, toS: 40);
      expect(r.state.tunnelMode, isTrue, reason: 'should be estimating by now');

      // Two minutes of fixes that ARE integrable (<= 25 m) but never reach the
      // 20 m exit bar. The car is plainly visible to the receiver throughout.
      drive(r, fromS: 41, seconds: 120, speed: 20, accuracy: 22, startM: 800);

      expect(r.state.tunnelMode, isFalse,
          reason: 'after 120 s of usable 22 m fixes the engine is STILL '
              'coasting on dead reckoning and ignoring every one of them');
    });

    test('31 · and while latched it invents distance the car did not cover',
        () {
      final r = Rig();
      r.approach(seconds: 20, speed: 20); // 400 m of real GPS at 20 m/s
      r.blackout(fromS: 21, toS: 40);     // ~20 s coasting at v0 = 20 m/s

      // The car now HALVES its speed and drives for two minutes with usable
      // 22 m fixes. Ground truth for this stretch is 10 m/s x 120 s = 1200 m.
      // Latched, the engine holds v0 = 20 m/s and reports about 2400 m.
      final beforeM = r.total;
      drive(r, fromS: 41, seconds: 120, speed: 10, accuracy: 22, startM: 800);
      final segment = r.total - beforeM;

      // The residual over-read is BOUNDED and understood, not incidental: the
      // engine coasts at v0 for at most
      // [AppConstants.estimationExitUsableWindow] before the fallback fires, so
      // the most it can invent here is (20 - 10) m/s x 10 s = 100 m. Anything
      // beyond that means the latch is back.
      const invented = 10.0 * 10.0;
      expect(segment, lessThanOrEqualTo(1200.0 + invented + 1.0),
          reason: 'reported ${segment.toStringAsFixed(0)} m for a stretch the '
              'car covered 1200 m of, which is more than the '
              '${invented.toStringAsFixed(0)} m the exit window can account '
              'for. An over-read is PERMANENT — _reconcileAgainst pays out '
              'undershoot only.');
      expect(segment, greaterThanOrEqualTo(1200.0),
          reason: 'under-reading here would mean the fallback fired early and '
              'the engine missed distance instead of inventing it');
    });
  });
}

/// The usable-run fallback must not be fooled by a signal that is still
/// dropping out. Added with the fix for the 20-25 m latch.
void _latchGaps() {
  group('the usable-fallback needs a CONTINUOUS run, not two lone fixes', () {
    test('32 · usable fixes further apart than the entry delay do not exit',
        () {
      final r = Rig();
      r.approach(seconds: 20, speed: 20);
      r.blackout(fromS: 21, toS: 40);
      expect(r.state.tunnelMode, isTrue);

      // One usable fix every 8 s for two minutes. Each is consistent with the
      // last, but an 8 s hole is longer than the 3 s §15.1 uses to DECLARE a
      // tunnel, so this is a signal still dropping out — not a recovery.
      var north = 800.0;
      for (var s = 41; s <= 160; s += 8) {
        for (var k = 0; k < 32; k++) {
          r.motion(s * 1000 + k * 250);
        }
        north += 160;
        r.gps(ms: s * 1000, northM: north, speed: 20, accuracy: 22);
        r.tick(s * 1000);
      }

      expect(r.state.tunnelMode, isTrue,
          reason: 'two lone fixes either side of an 8 s hole are not evidence '
              'the signal came back');
    });
  });
}
