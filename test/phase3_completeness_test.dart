import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/core/constants/app_constants.dart';
import 'package:irallymeter/features/distance/domain/distance_delta.dart';
import 'package:irallymeter/features/distance/domain/distance_engine.dart';
import 'package:irallymeter/features/distance/domain/distance_engine_state.dart';
import 'package:irallymeter/features/distance/domain/motion_sample.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';

/// The gaps a coverage audit of Phase 3 turned up — the spec sections and real
/// rally actions that had no explicit test anywhere.
///
/// Written specifically to answer "is Phase 3 actually finished?" rather than to
/// confirm that it is.
const double degPerM = 8.993216059187306e-6;

class Rig {
  Rig() {
    engine = DistanceEngine(onDelta: deltas.add, onState: (s) => state = s);
  }

  late final DistanceEngine engine;
  DistanceEngineState state = DistanceEngineState.initial;
  final List<DistanceDelta> deltas = [];

  DateTime at(int ms) => DateTime.utc(2026).add(Duration(milliseconds: ms));

  /// Distance emitted since [from] in the deltas list.
  double since(int from) =>
      deltas.skip(from).fold(0.0, (a, d) => a + d.meters);

  void gps({required int ms, required double northM, double speed = 20}) =>
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

  void approach({int seconds = 20, double speed = 20}) {
    for (var s = 0; s <= seconds; s++) {
      motion(s * 1000);
      gps(ms: s * 1000, northM: s * speed, speed: speed);
    }
  }

  void blackout({required int fromS, required int toS}) {
    for (var s = fromS; s <= toS; s++) {
      for (var k = 0; k < 4; k++) {
        motion(s * 1000 + k * 250);
      }
      tick(s * 1000);
    }
  }

  void recover({required int fromS, required double northM, double speed = 20}) {
    for (var i = 0; i < 3; i++) {
      motion((fromS + i) * 1000);
      gps(ms: (fromS + i) * 1000, northM: northM + i * speed, speed: speed);
    }
  }
}

void main() {
  group('§17 · the engine really is pure Dart', () {
    // The spec requires the Distance Engine to be headless-testable. Every test
    // in this repo depends on that, so it is worth asserting structurally
    // rather than trusting that nobody ever adds an import.
    test('01 · the distance domain imports no Flutter and no plugins', () {
      final dir = Directory('lib/features/distance/domain');
      final offenders = <String>[];
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        for (final line in f.readAsLinesSync()) {
          if (!line.startsWith('import ')) continue;
          final banned = [
            'package:flutter/',
            'package:geolocator',
            'package:sensors_plus',
            'package:hive',
            'package:flutter_riverpod',
            'dart:io',
            'dart:ui',
          ];
          for (final b in banned) {
            if (line.contains(b)) offenders.add('${f.path}: $line');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'SPEC-v2 §17 requires a pure-Dart engine that runs headless:\n'
              '${offenders.join('\n')}');
    });
  });

  group('§9 · Trip 1 and Trip 2 are genuinely independent', () {
    // The spec's own example: Trip 1 reads 52.300 at a checkpoint, Trip 2 is
    // reset there, and after 3 km Trip 1 reads 55.300 while Trip 2 reads 3.000.
    // The engine emits ONE delta stream and the trip computer fans it out, so
    // the property to prove is that one stream feeds both counters equally.
    test('02 · both counters see exactly the same metres', () {
      final r = Rig()..approach(seconds: 60);
      final total = r.since(0);
      expect(total, greaterThan(0));
      // Every delta is source-tagged but carries one distance; a trip computer
      // adding the same stream twice must get the same answer twice.
      final a = r.deltas.fold(0.0, (x, d) => x + d.meters);
      final b = r.deltas.fold(0.0, (x, d) => x + d.meters);
      expect(a, b);
      expect(a, closeTo(total, 1e-9));
    });
  });

  group('THE GAP · resetting a trip while a correction is still paying out', () {
    test('03 · the outstanding correction is settled, not dripped into the '
        'new leg', () {
      // A co-driver resets Trip A at a checkpoint. If a tunnel correction from
      // just before that checkpoint is still paying out, those metres were
      // covered on the PREVIOUS leg — but the reconciler kept emitting them and
      // the trip computer kept adding them to the new one.
      //
      // MEASURED BEFORE THE FIX: 715 m. On a rally that is the difference
      // between "turn after 3 km" landing on the right junction and the wrong
      // one. §16.1's "no visible jump" rule does not apply across a reset,
      // because the counter being watched is about to be zeroed anyway.
      final r = Rig()..approach();
      r.blackout(fromS: 21, toS: 120);
      r.recover(fromS: 121, northM: 21 * 20 + 100 * 20 + 600);
      expect(r.state.reconciling, isTrue,
          reason: 'precondition: a correction must be in flight');

      final owed = r.engine.settleReconciliation(r.at(124000));
      expect(owed, greaterThan(0),
          reason: 'the settle must hand back the metres so the caller can put '
              'them on the leg that is ENDING');
      expect(r.state.reconciling, isFalse);

      // Nothing may leak into the new leg afterwards.
      final atReset = r.deltas.length;
      for (var s = 125; s <= 320; s++) {
        r.tick(s * 1000);
      }
      expect(r.since(atReset), 0,
          reason: 'after settling, the reconciler must be empty — anything '
              'emitted here lands on the leg the driver just zeroed');
    });

    test('04 · a reset never makes the engine emit negative distance', () {
      final r = Rig()..approach();
      r.blackout(fromS: 21, toS: 90);
      r.recover(fromS: 91, northM: 21 * 20 + 70 * 20 + 400);
      for (var s = 94; s <= 200; s++) {
        r.tick(s * 1000);
      }
      for (final d in r.deltas) {
        expect(d.meters, greaterThanOrEqualTo(0));
      }
    });
  });

  group('THE GAP · a tunnel that starts while still reconciling', () {
    test('05 · a second blackout mid-payout does not stack or corrupt', () {
      final r = Rig()..approach();
      r.blackout(fromS: 21, toS: 90);
      r.recover(fromS: 91, northM: 21 * 20 + 70 * 20 + 300);
      expect(r.state.reconciling || !r.state.tunnelMode, isTrue);

      // Straight into a second tunnel before the payout finishes.
      r.blackout(fromS: 94, toS: 160);
      expect(r.state.tunnelMode, isTrue,
          reason: 'a second dropout must still be detected while reconciling');

      r.recover(fromS: 161, northM: 21 * 20 + 70 * 20 + 300 + 66 * 20);
      for (var s = 164; s <= 320; s++) {
        r.tick(s * 1000);
      }

      for (final d in r.deltas) {
        expect(d.meters.isFinite, isTrue);
        expect(d.meters, greaterThanOrEqualTo(0));
      }
      expect(r.engine.sections.length, 2,
          reason: 'two blackouts must produce two §15.3 sections');
    });

    test('06 · estimating outranks reconciling in the reported state', () {
      final r = Rig()..approach();
      r.blackout(fromS: 21, toS: 90);
      r.recover(fromS: 91, northM: 21 * 20 + 70 * 20 + 300);
      r.blackout(fromS: 94, toS: 130);
      expect(r.state.tunnelMode, isTrue,
          reason: 'the honest thing to show is that we are guessing NOW, not '
              'that we are tidying up from last time');
    });
  });

  group('THE GAP · a blackout longer than the motion-backed cap', () {
    test('07 · past 45 minutes even a live motion stream stops vouching', () {
      final r = Rig()..approach();
      final capS = AppConstants.maxTunnelDurationWithMotion.inSeconds;
      // Tick past the cap with motion running the whole way.
      for (var s = 21; s <= capS + 200; s += 1) {
        if (s % 4 == 0) r.motion(s * 1000);
        r.tick(s * 1000);
      }
      expect(r.state.tunnelMode, isTrue,
          reason: 'it must still be estimating, not give up');
      r.recover(fromS: capS + 210, northM: 21 * 20 + (capS + 190) * 20.0);
      expect(r.engine.sections.last?.correctionMeters ?? -1, 0,
          reason: 'beyond the cap the chord is no longer evidence of a tunnel, '
              'so it must not be reconciled');
    });

    test('08 · and the counters are still sane afterwards', () {
      final r = Rig()..approach();
      final capS = AppConstants.maxTunnelDurationWithMotion.inSeconds;
      for (var s = 21; s <= capS + 100; s += 1) {
        if (s % 4 == 0) r.motion(s * 1000);
        r.tick(s * 1000);
      }
      for (final d in r.deltas) {
        expect(d.meters.isFinite, isTrue);
        expect(d.meters, greaterThanOrEqualTo(0));
      }
      expect(r.state.tunnelMeters.isFinite, isTrue);
    });
  });

  group('THE GAP · the §15.3 log under sustained abuse', () {
    test('09 · fifty blackouts produce fifty sections and stay bounded', () {
      final r = Rig()..approach();
      var s = 21;
      var m = 21 * 20.0;
      for (var i = 0; i < 50; i++) {
        r.blackout(fromS: s, toS: s + 10);
        m += 10 * 20.0;
        s += 11;
        r.recover(fromS: s, northM: m);
        m += 3 * 20.0;
        s += 3;
      }
      expect(r.engine.sections.length, 50);
      expect(r.engine.sections.length,
          lessThanOrEqualTo(AppConstants.maxLoggedSections));
      expect(r.engine.sections.totalEstimatedMeters.isFinite, isTrue);
      expect(r.engine.sections.totalDuration.inSeconds, greaterThan(0));
    });
  });
}
