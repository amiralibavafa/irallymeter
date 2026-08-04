import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/core/constants/app_constants.dart';
import 'package:irallymeter/features/distance/domain/distance_delta.dart';
import 'package:irallymeter/features/distance/domain/distance_engine.dart';
import 'package:irallymeter/features/distance/domain/distance_engine_state.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';

/// SPEC-v2 §15.1 / §15.2 — when Estimation Mode starts and, more importantly,
/// when it is allowed to stop.
const double degPerM = 8.993216059187306e-6;

class Rig {
  Rig() {
    engine = DistanceEngine(onDelta: (_) {}, onState: (s) => state = s);
  }

  late final DistanceEngine engine;
  DistanceEngineState state = DistanceEngineState.initial;

  DateTime at(int ms) => DateTime.utc(2026).add(Duration(milliseconds: ms));

  void gps({
    required int ms,
    double northM = 0,
    double speed = 20,
    double accuracy = 5,
  }) =>
      engine.onGpsSample(
        GpsSample(
          timestamp: at(ms),
          latitude: 46.0 + northM * degPerM,
          longitude: 8.0,
          speedMps: speed,
          speedAccuracyMps: 0.5,
          headingDeg: 0,
          accuracyM: accuracy,
          altitudeM: 0,
          hasFix: true,
        ),
        at(ms),
      );

  void tick(int ms) => engine.tick(at(ms));

  /// Two good fixes, then silence until the engine gives up on GPS.
  void driveIntoTunnel() {
    gps(ms: 0, northM: 0);
    gps(ms: 1000, northM: 20);
    tick(4100); // > 3 s since the last healthy fix
    expect(state.tunnelMode, isTrue, reason: 'rig precondition');
  }
}

void main() {
  group('§15.1 · entering Estimation Mode', () {
    test('01 · the silence threshold is 3 seconds, as the spec states', () {
      expect(AppConstants.tunnelConfirmDelay, const Duration(seconds: 3));
    });

    test('02 · a couple of skipped fixes do not trigger it', () {
      final r = Rig()
        ..gps(ms: 0)
        ..gps(ms: 1000, northM: 20);
      r.tick(3500); // 2.5 s of silence
      expect(r.state.tunnelMode, isFalse,
          reason: 'the display must not flap on a brief gap');
    });

    test('03 · more than 3 s of silence does trigger it', () {
      final r = Rig()
        ..gps(ms: 0)
        ..gps(ms: 1000, northM: 20);
      r.tick(4100);
      expect(r.state.tunnelMode, isTrue);
    });

    test('04 · a fix worse than 50 m enters immediately, without waiting', () {
      // A fix this poor is worse than the estimate that would replace it, so
      // holding it for another three seconds only pollutes the trip.
      final r = Rig()
        ..gps(ms: 0)
        ..gps(ms: 1000, northM: 20);
      r.gps(ms: 1200, northM: 24, accuracy: 60);
      expect(r.state.tunnelMode, isTrue);
      expect(AppConstants.estimationEntryAccuracyMeters, 50.0);
    });

    test('05 · a merely degraded fix waits rather than abandoning GPS', () {
      // Between usableAccuracyMeters and 50 m the engine neither integrates the
      // fix nor gives up on the receiver. That gap is deliberate.
      final r = Rig()
        ..gps(ms: 0)
        ..gps(ms: 1000, northM: 20);
      r.gps(ms: 1200, northM: 24, accuracy: 35);
      expect(r.state.tunnelMode, isFalse);
      expect(AppConstants.usableAccuracyMeters, lessThan(35));
    });

    test('06 · a cold start with no signal estimates nothing', () {
      final r = Rig();
      r.tick(10000);
      expect(r.state.tunnelMode, isFalse,
          reason: 'no prior fix means no entry speed to anchor to; waiting is '
              'the honest answer, not guessing');
    });
  });

  group('§15.2 · exiting Estimation Mode', () {
    test('07 · the exit criterion is a COUNT of fixes, not a duration', () {
      expect(AppConstants.estimationExitConsecutiveFixes, 3);
      expect(AppConstants.estimationExitAccuracyMeters, 20.0);
    });

    test('08 · one reacquired fix does not end it', () {
      final r = Rig()..driveIntoTunnel();
      r.gps(ms: 5200, northM: 100, accuracy: 5);
      expect(r.state.tunnelMode, isTrue);
    });

    test('09 · two do not end it either', () {
      final r = Rig()..driveIntoTunnel();
      r.gps(ms: 5200, northM: 100, accuracy: 5);
      r.gps(ms: 6200, northM: 120, accuracy: 5);
      expect(r.state.tunnelMode, isTrue,
          reason: 'a tunnel mouth throws out a burst of plausible-but-wrong '
              'fixes; two agreeing is not yet evidence');
    });

    test('10 · three consecutive good fixes end it', () {
      final r = Rig()..driveIntoTunnel();
      r.gps(ms: 5200, northM: 100, accuracy: 5);
      r.gps(ms: 6200, northM: 120, accuracy: 5);
      r.gps(ms: 7200, northM: 140, accuracy: 5);
      expect(r.state.tunnelMode, isFalse);
      expect(r.state.source, DistanceSource.gps);
    });

    test('11 · a fix worse than 20 m resets the streak', () {
      final r = Rig()..driveIntoTunnel();
      r.gps(ms: 5200, northM: 100, accuracy: 5);
      r.gps(ms: 6200, northM: 120, accuracy: 5);
      r.gps(ms: 7200, northM: 140, accuracy: 24); // usable, but not 20 m good
      expect(r.state.tunnelMode, isTrue,
          reason: '24 m is still integrable, but §15.2 wants 20 m or better '
              'before it will believe a recovery');

      r.gps(ms: 8200, northM: 160, accuracy: 5);
      r.gps(ms: 9200, northM: 180, accuracy: 5);
      expect(r.state.tunnelMode, isTrue, reason: 'streak restarted, only 2 so far');

      r.gps(ms: 10200, northM: 200, accuracy: 5);
      expect(r.state.tunnelMode, isFalse);
    });

    test('12 · a mutually inconsistent fix restarts the count', () {
      // §15.2: "each implies a plausible speed relative to the previous one".
      final r = Rig()..driveIntoTunnel();
      r.gps(ms: 5200, northM: 100, accuracy: 5);
      r.gps(ms: 6200, northM: 120, accuracy: 5);
      // 5 km in one second — re-acquisition noise, not driving.
      r.gps(ms: 7200, northM: 5120, accuracy: 5);
      expect(r.state.tunnelMode, isTrue,
          reason: 'the teleport cannot be the third confirming fix');

      r.gps(ms: 8200, northM: 5140, accuracy: 5);
      r.gps(ms: 9200, northM: 5160, accuracy: 5);
      expect(r.state.tunnelMode, isFalse,
          reason: 'the teleport restarted the streak AT itself, so two more '
              'consistent fixes complete it');
    });

    test('13 · the estimate keeps running while recovery is unconfirmed', () {
      final r = Rig()..driveIntoTunnel();
      final before = r.state.tunnelMeters;
      r.gps(ms: 5200, northM: 100, accuracy: 5);
      r.gps(ms: 6200, northM: 120, accuracy: 5);
      expect(r.state.tunnelMode, isTrue);
      expect(r.state.tunnelMeters, greaterThanOrEqualTo(before),
          reason: 'holding the estimate is the point of the debounce');
    });
  });
}
