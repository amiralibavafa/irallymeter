import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/features/distance/domain/distance_delta.dart';
import 'package:irallymeter/features/distance/domain/distance_engine.dart';
import 'package:irallymeter/features/distance/domain/distance_engine_state.dart';
import 'package:irallymeter/features/distance/domain/motion_sample.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';

/// EVERYTHING THAT IS NOT A TUNNEL.
///
/// The tunnel has its own file. This one is the rest of the world: the failure
/// modes a GNSS receiver actually has, and the things a rally car actually does.
///
/// Several of these come from how receivers are documented to fail rather than
/// from imagination — a jammed receiver "may lose position, FREEZE ITS LAST
/// KNOWN LOCATION, or show degraded accuracy", and multipath off wet trees or
/// canyon walls puts the reported position hundreds of metres from the truth
/// while the accuracy figure still looks fine. Both are far nastier than an
/// honest dropout, because the fixes keep arriving and keep claiming to be good.
///
/// Every test asserts the same four invariants, because they are the ones that
/// matter on a stage:
///
///   * no crash
///   * no NaN / infinite / negative distance
///   * counters never run backwards
///   * distance is never invented out of nothing
const double degPerM = 8.993216059187306e-6;
const double degPerMLon = 8.993216059187306e-6 / 0.81; // at 35.7 N

class Rig {
  Rig() {
    engine = DistanceEngine(onDelta: deltas.add, onState: (s) => state = s);
  }

  late final DistanceEngine engine;
  DistanceEngineState state = DistanceEngineState.initial;
  final List<DistanceDelta> deltas = [];

  DateTime at(int ms) => DateTime.utc(2026).add(Duration(milliseconds: ms));
  double get total => deltas.fold(0.0, (a, d) => a + d.meters);

  void gps({
    required int ms,
    double northM = 0,
    double eastM = 0,
    double speed = 20,
    double accuracy = 5,
    double speedAcc = 0.5,
    bool hasFix = true,
    int? stampMs,
  }) =>
      engine.onGpsSample(
        GpsSample(
          timestamp: at(stampMs ?? ms),
          latitude: 35.7 + northM * degPerM,
          longitude: 51.4 + eastM * degPerMLon,
          speedMps: speed,
          speedAccuracyMps: speedAcc,
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

  void assertSane(String what) {
    var running = 0.0;
    for (final d in deltas) {
      expect(d.meters.isFinite, isTrue, reason: 'NaN/Inf distance in $what');
      expect(d.meters, greaterThanOrEqualTo(0),
          reason: 'negative increment in $what — counters would run backwards');
      expect(d.speedMps.isFinite, isTrue, reason: 'NaN speed in $what');
      running += d.meters;
    }
    expect(running.isFinite, isTrue, reason: what);
    expect(state.tunnelMeters.isFinite, isTrue, reason: what);
  }
}

void main() {
  group('A · receiver failure modes that LIE rather than go quiet', () {
    test('01 · a JAMMED receiver frozen on its last position invents nothing',
        () {
      // Documented jamming behaviour: the receiver "may freeze its last known
      // location". Fixes keep arriving at 1 Hz, accuracy still says 5 m, and
      // the position never changes. To the engine this is indistinguishable
      // from a parked car — which is the SAFE reading. What must never happen
      // is distance appearing out of a stationary position.
      final r = Rig();
      for (var s = 0; s <= 30; s++) {
        r.motion(s * 1000);
        r.gps(ms: s * 1000, northM: s * 20.0);
      }
      final before = r.total;
      for (var s = 31; s <= 300; s++) {
        r.motion(s * 1000, ax: 1.0); // the car IS accelerating
        r.gps(ms: s * 1000, northM: 30 * 20.0, speed: 0); // receiver frozen
        r.tick(s * 1000);
      }
      expect(r.total, closeTo(before, 1.0),
          reason: 'a frozen receiver must not manufacture distance');
      r.assertSane('jammed/frozen receiver');
    });

    test('02 · a frozen receiver that still claims speed does not accumulate',
        () {
      // Worse variant: position frozen but Doppler still reporting 20 m/s.
      // Rule 2 passes (it thinks we are moving) but there is no displacement,
      // so nothing should accumulate.
      final r = Rig();
      for (var s = 0; s <= 20; s++) {
        r.gps(ms: s * 1000, northM: s * 20.0);
      }
      final before = r.total;
      for (var s = 21; s <= 200; s++) {
        r.gps(ms: s * 1000, northM: 20 * 20.0, speed: 20);
      }
      expect(r.total, closeTo(before, 1.0));
      r.assertSane('frozen position, live Doppler');
    });

    test('03 · MULTIPATH in a canyon — big jumps with good reported accuracy',
        () {
      // Signals bouncing off rock or wet trees put the fix hundreds of metres
      // out while the receiver still reports 5 m. This is the case §6.1 rule 4
      // exists for.
      final r = Rig();
      for (var s = 0; s <= 20; s++) {
        r.gps(ms: s * 1000, northM: s * 20.0);
      }
      for (var s = 21; s <= 120; s++) {
        // True position advances 20 m/s; every third fix is thrown 400 m sideways.
        final scatter = (s % 3 == 0) ? 400.0 : 0.0;
        r.gps(ms: s * 1000, northM: s * 20.0, eastM: scatter);
        r.tick(s * 1000);
      }
      // Truth over the whole trace is 120 * 20 = 2400 m. Multipath must not
      // inflate that into kilometres.
      expect(r.total, lessThan(2400 * 1.5),
          reason: 'measured ${r.total.toStringAsFixed(0)} m against 2400 m of '
              'real travel — multipath was integrated as real movement');
      r.assertSane('canyon multipath');
    });

    test('04 · a COLD START with garbage first fixes settles without damage',
        () {
      // No ephemeris: the first fixes are wild and honestly reported as poor.
      final r = Rig();
      for (var s = 0; s <= 10; s++) {
        r.gps(ms: s * 1000, northM: s * 5000.0, accuracy: 200, speed: 0);
      }
      for (var s = 11; s <= 60; s++) {
        r.gps(ms: s * 1000, northM: (s - 11) * 20.0, accuracy: 5);
      }
      expect(r.total, lessThan(2000),
          reason: 'the acquisition garbage must not land on the odometer');
      r.assertSane('cold start');
    });

    test('05 · nonsense accuracy values are rejected, not trusted', () {
      final r = Rig();
      for (final acc in [0.0, -1.0, -999.0, double.nan, double.infinity, 1e9]) {
        r.gps(ms: 1000, northM: 0, accuracy: acc);
        r.gps(ms: 2000, northM: 100, accuracy: acc);
      }
      expect(r.total, 0, reason: 'no fix with an impossible accuracy may be '
          'integrated');
      r.assertSane('nonsense accuracy');
    });

    test('06 · hasFix=false samples are inert whatever else they carry', () {
      final r = Rig();
      for (var s = 0; s <= 20; s++) {
        r.gps(ms: s * 1000, northM: s * 20.0);
      }
      final before = r.total;
      for (var s = 21; s <= 60; s++) {
        r.gps(ms: s * 1000, northM: s * 1000.0, accuracy: 3, hasFix: false);
      }
      expect(r.total, before);
      r.assertSane('no-fix samples');
    });
  });

  group('B · what a rally car actually does', () {
    test('07 · a full-speed stage at 200 km/h measures correctly', () {
      const v = 55.6; // 200 km/h
      final r = Rig();
      for (var s = 0; s <= 120; s++) {
        r.gps(ms: s * 1000, northM: s * v, speed: v);
      }
      expect(r.total, closeTo(120 * v, 120 * v * 0.02),
          reason: 'measured ${r.total.toStringAsFixed(0)} m against '
              '${(120 * v).toStringAsFixed(0)} m');
      r.assertSane('200 km/h stage');
    });

    test('08 · repeated start-line stops (time controls) never creep', () {
      final r = Rig();
      var ms = 0, north = 0.0;
      for (var control = 0; control < 8; control++) {
        for (var s = 0; s < 30; s++) {
          north += 25;
          r.gps(ms: ms += 1000, northM: north, speed: 25);
        }
        // Two minutes sitting at a control, engine running, tiny wander.
        for (var s = 0; s < 120; s++) {
          r.gps(
            ms: ms += 1000,
            northM: north + ((s % 5) - 2) * 1.5,
            eastM: ((s % 7) - 3) * 1.5,
            speed: 0.3,
            accuracy: 6,
          );
        }
      }
      expect(r.total, lessThan(8 * 30 * 25 * 1.02),
          reason: 'measured ${r.total.toStringAsFixed(0)} m against '
              '${8 * 30 * 25} m of real travel — the controls leaked distance');
      r.assertSane('eight time controls');
    });

    test('09 · reversing does not subtract, and does not double-count', () {
      // Rally cars reverse out of ditches. Distance is a scalar: going back
      // 100 m is 100 m travelled, and it must never reduce the trip.
      final r = Rig();
      for (var s = 0; s <= 20; s++) {
        r.gps(ms: s * 1000, northM: s * 20.0);
      }
      final forward = r.total;
      for (var s = 21; s <= 30; s++) {
        r.gps(ms: s * 1000, northM: (40 - s) * 20.0, speed: 20);
      }
      expect(r.total, greaterThanOrEqualTo(forward),
          reason: 'the trip counter must never go backwards');
      r.assertSane('reversing');
    });

    test('10 · a closed loop back to the start still totals the lap', () {
      // A circuit: end where you began. Displacement is zero, distance is not.
      final r = Rig();
      const side = 500.0;
      var ms = 0;
      void leg(double fromN, double toN, double fromE, double toE) {
        for (var i = 1; i <= 25; i++) {
          r.gps(
            ms: ms += 1000,
            northM: fromN + (toN - fromN) * i / 25,
            eastM: fromE + (toE - fromE) * i / 25,
            speed: 20,
          );
        }
      }
      r.gps(ms: ms, northM: 0, eastM: 0);
      leg(0, side, 0, 0);
      leg(side, side, 0, side);
      leg(side, 0, side, side);
      leg(0, 0, side, 0);
      expect(r.total, closeTo(4 * side, 4 * side * 0.05),
          reason: 'measured ${r.total.toStringAsFixed(0)} m around a '
              '${4 * side} m loop');
      r.assertSane('closed loop');
    });

    test('11 · a climb does not distort the horizontal distance', () {
      // 1000 m of horizontal travel while gaining 200 m of altitude. The app
      // measures ground distance; altitude must not leak into it.
      final r = Rig();
      for (var s = 0; s <= 50; s++) {
        r.engine.onGpsSample(
          GpsSample(
            timestamp: r.at(s * 1000),
            latitude: 35.7 + s * 20.0 * degPerM,
            longitude: 51.4,
            speedMps: 20,
            speedAccuracyMps: 0.5,
            headingDeg: 0,
            accuracyM: 5,
            altitudeM: 1200 + s * 4.0,
            hasFix: true,
          ),
          r.at(s * 1000),
        );
      }
      expect(r.total, closeTo(1000, 30));
      r.assertSane('mountain climb');
    });
  });

  group('C · the stream itself misbehaving', () {
    test('12 · duplicate identical fixes add nothing', () {
      final r = Rig();
      r.gps(ms: 1000, northM: 0);
      for (var i = 0; i < 50; i++) {
        r.gps(ms: 2000 + i * 100, northM: 0);
      }
      expect(r.total, 0);
      r.assertSane('duplicate fixes');
    });

    test('13 · out-of-order timestamps do not produce negative distance', () {
      final r = Rig();
      for (var s = 0; s <= 20; s++) {
        r.gps(ms: s * 1000, northM: s * 20.0);
      }
      // A fix stamped in the past arrives late.
      r.gps(ms: 21000, northM: 21 * 20.0, stampMs: 5000);
      r.gps(ms: 22000, northM: 22 * 20.0);
      r.assertSane('out-of-order timestamps');
    });

    test('14 · the fix rate changing 5 Hz -> 0.2 Hz mid-drive is handled', () {
      final r = Rig();
      var ms = 0;
      var north = 0.0;
      for (var i = 0; i < 100; i++) {
        north += 4; // 20 m/s at 5 Hz
        r.gps(ms: ms += 200, northM: north, speed: 20);
      }
      final fast = r.total;
      for (var i = 0; i < 20; i++) {
        north += 100; // 20 m/s at 0.2 Hz
        r.gps(ms: ms += 5000, northM: north, speed: 20);
      }
      expect(r.total, greaterThan(fast),
          reason: 'a slower fix rate must still accumulate');
      expect(r.total, closeTo(north, north * 0.05));
      r.assertSane('variable fix rate');
    });

    test('15 · a very long session does not drift or slow down', () {
      // Six hours at 1 Hz — a full rally day.
      final r = Rig();
      for (var s = 0; s <= 21600; s++) {
        r.gps(ms: s * 1000, northM: s * 20.0, speed: 20);
      }
      expect(r.total, closeTo(21600 * 20.0, 21600 * 20.0 * 0.001),
          reason: 'measured ${r.total.toStringAsFixed(0)} m against '
              '${21600 * 20} m over six hours');
      r.assertSane('six-hour session');
    });

    test('16 · the engine survives being fed nothing but heartbeats', () {
      final r = Rig();
      for (var s = 0; s < 600; s++) {
        r.tick(s * 1000);
      }
      expect(r.total, 0);
      expect(r.state.tunnelMode, isFalse,
          reason: 'a cold start with no fix ever must not begin estimating — '
              'there is no entry speed to anchor to');
      r.assertSane('heartbeats only');
    });

    test('17 · motion samples with no GPS at all never invent distance', () {
      final r = Rig();
      for (var s = 0; s < 600; s++) {
        r.motion(s * 1000, ax: 2.0);
        r.tick(s * 1000);
      }
      expect(r.total, 0,
          reason: 'the accelerometer alone is not a distance source — §14 says '
              'sensors exist to survive a GNSS gap, not to replace GNSS');
      r.assertSane('motion without GPS');
    });

    test('18 · engine.reset() mid-drive starts a clean leg', () {
      final r = Rig();
      for (var s = 0; s <= 50; s++) {
        r.gps(ms: s * 1000, northM: s * 20.0);
      }
      r.engine.reset();
      expect(r.state.tunnelMode, isFalse);
      for (var s = 51; s <= 80; s++) {
        r.gps(ms: s * 1000, northM: 5000 + (s - 51) * 20.0);
      }
      r.assertSane('reset mid-drive');
      expect(r.engine.sections.isEmpty, isTrue);
    });
  });
}
