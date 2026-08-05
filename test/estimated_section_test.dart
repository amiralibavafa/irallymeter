import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/core/constants/app_constants.dart';
import 'package:irallymeter/features/distance/domain/distance_engine.dart';
import 'package:irallymeter/features/distance/domain/distance_engine_state.dart';
import 'package:irallymeter/features/distance/domain/estimated_section.dart';
import 'package:irallymeter/features/distance/domain/motion_sample.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';

/// SPEC-v2 §15.3 — "Every estimated section is recorded automatically without
/// user action."
///
/// This replaces the manual TUNNEL START / TUNNEL END buttons §15 deleted. The
/// spec's own justification is what these tests hold the implementation to:
/// the record is "measured rather than hand-triggered", and it exists to give
/// "the data needed to tune the thresholds during testing".
const double degPerM = 8.993216059187306e-6;

class Rig {
  Rig() {
    engine = DistanceEngine(
      onDelta: (_) {},
      onState: (s) => state = s,
      onSection: emitted.add,
    );
  }

  late final DistanceEngine engine;
  DistanceEngineState state = DistanceEngineState.initial;
  final List<EstimatedSection> emitted = [];

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

  /// Quiet motion samples — no net acceleration, so §12.2 coasts at v₀.
  void coast({required int fromMs, required int toMs}) {
    for (var t = fromMs + 250; t <= toMs; t += 250) {
      engine.onMotionSample(
        MotionSample(
          timestamp: at(t),
          userAccel: Vec3.zero,
          gravity: const Vec3(0, 0, 9.81),
          gyro: Vec3.zero,
        ),
        at(t),
      );
    }
  }

  /// Two good fixes at [speed], then silence until the engine gives up.
  void driveIntoTunnel({double speed = 20}) {
    gps(ms: 0, northM: 0, speed: speed);
    gps(ms: 1000, northM: 20, speed: speed);
    tick(4100);
    expect(state.tunnelMode, isTrue, reason: 'rig precondition');
  }

  /// Three consecutive confirming fixes ending the section (§15.2).
  void recoverAt({required int ms, required double northM, double step = 20}) {
    gps(ms: ms, northM: northM);
    gps(ms: ms + 1000, northM: northM + step);
    gps(ms: ms + 2000, northM: northM + 2 * step);
    expect(state.tunnelMode, isFalse, reason: 'rig precondition');
  }
}

void main() {
  group('§15.3 · a section is recorded without any user action', () {
    test('01 · nothing is logged before anything is estimated', () {
      final r = Rig()
        ..gps(ms: 0)
        ..gps(ms: 1000, northM: 20);
      expect(r.engine.sections.isEmpty, isTrue);
      expect(r.emitted, isEmpty);
    });

    test('02 · an open section is not logged — only a completed one is', () {
      final r = Rig()..driveIntoTunnel();
      r.coast(fromMs: 4100, toMs: 8000);
      expect(r.state.tunnelMode, isTrue);
      expect(r.engine.sections.isEmpty, isTrue,
          reason: 'a section with no end has no duration and no correction; '
              'there is nothing honest to record yet');
    });

    test('03 · exiting Estimation Mode records exactly one section', () {
      final r = Rig()..driveIntoTunnel();
      r.coast(fromMs: 4100, toMs: 8000);
      r.recoverAt(ms: 8200, northM: 200);

      expect(r.engine.sections.length, 1);
      expect(r.emitted.length, 1,
          reason: 'the callback and the log must agree');
      expect(identical(r.emitted.single, r.engine.sections.sections.single),
          isTrue);
    });

    test('04 · start, end and duration are the measured ones', () {
      final r = Rig()..driveIntoTunnel();
      r.coast(fromMs: 4100, toMs: 8000);
      r.recoverAt(ms: 8200, northM: 200);

      final s = r.engine.sections.last!;
      // Entry is the heartbeat that noticed 3 s of silence; exit is the third
      // confirming fix, not the first one back.
      expect(s.start, r.at(4100));
      // [SA-V2 10]: the section ends when the blackout ends — the first usable
      // fix at 8200 — not when §15.2 confirms recovery two fixes later. That is
      // the point of provisional measuring: from 8200 the engine MEASURES, so
      // 8200-10200 was never estimated and does not belong in an estimated
      // section. The recorded duration is now the true dark time.
      expect(s.end, r.at(8200));
      // 4.1 s, not 6.1 s: the section spans the BLACKOUT (4100 -> 8200), not
      // the blackout plus the two fixes §15.2 spends confirming. See the note
      // on `s.end` above.
      expect(s.duration, const Duration(milliseconds: 4100));
      expect(s.end.isAfter(s.start), isTrue);
    });

    test('05 · the held speed is the ENTRY anchor v0, not the exit speed', () {
      // §12.2 holds the entry speed and lets the accelerometer refine it only
      // within ±25 %. v0 is therefore the number that decides whether a
      // section can be trusted at all — which is the point of logging it.
      final r = Rig()..driveIntoTunnel(speed: 30);
      r.coast(fromMs: 4100, toMs: 8000);
      r.recoverAt(ms: 8200, northM: 300);

      expect(r.engine.sections.last!.heldSpeedMps, closeTo(30.0, 1e-9));
    });

    test('06 · the correction applied on recovery is recorded', () {
      // FIXTURE MADE PHYSICAL, ASSERTION UNCHANGED. This used to go dark for
      // 4.1 s and reappear 380 m away — 92.7 m/s, or 334 km/h. It passed only
      // because reconciliation ran at the THIRD confirming fix, inflating the
      // duration until the implied speed slipped under the old flat 90 m/s cap.
      // CODEX-3 now judges the chord against the car's own Doppler speeds, so
      // the geometry has to be one a car could drive: 15 s dark at 20 m/s.
      final r = Rig()..driveIntoTunnel();
      r.coast(fromMs: 4100, toMs: 19000);
      r.recoverAt(ms: 19200, northM: 400);

      final s = r.engine.sections.last!;
      // Entry fix was 20 m north; the DARK-END fix — the first usable one, at
      // 400 m — is what the estimate is reconciled against now, not the fix
      // that completes the streak. So GPS can prove a 380 m chord.
      final chord = 380.0;
      expect(s.estimatedMeters, greaterThan(0),
          reason: 'coasting at 20 m/s for ~4 s must estimate something');
      expect(s.correctionMeters, closeTo(chord - s.estimatedMeters, 1e-6));
      expect(s.uncorrected, isFalse);
      expect(s.shortfallFraction, greaterThan(0));
    });

    test('07 · a section whose estimate OVERSHOT is still logged, with zero',
        () {
      // §16 corrects undershoot only — the entry→exit chord is a lower bound on
      // road distance, so an overshoot proves nothing. The section must still
      // appear: "estimate ran long" is precisely what threshold tuning wants.
      final r = Rig()..driveIntoTunnel(speed: 30);
      r.coast(fromMs: 4100, toMs: 20000);
      r.recoverAt(ms: 20200, northM: 60, step: 5);

      final s = r.engine.sections.last!;
      expect(s.estimatedMeters, greaterThan(100));
      expect(s.correctionMeters, 0);
      expect(s.uncorrected, isTrue);
      expect(s.shortfallFraction, isNull,
          reason: 'nothing was proven, so there is no error to report');
    });

    test('08 · a blackout too long to be a tunnel is logged, uncorrected', () {
      // A suspended app looks exactly like a tunnel from the engine's side.
      // §16 declines to reconcile it; §15.3 still has to record it, because a
      // long duration with a zero correction is how that case is recognised.
      final r = Rig()..driveIntoTunnel();
      final resumeMs = AppConstants.maxTunnelDuration.inMilliseconds + 30000;
      r.recoverAt(ms: resumeMs, northM: 50000);

      final s = r.engine.sections.last!;
      expect(s.duration, greaterThan(AppConstants.maxTunnelDuration));
      expect(s.correctionMeters, 0,
          reason: 'inventing 50 km of unmeasured driving is far worse than '
              'missing it');
    });

    test('09 · consecutive sections each get their own row', () {
      final r = Rig()..driveIntoTunnel();
      r.coast(fromMs: 4100, toMs: 8000);
      r.recoverAt(ms: 8200, northM: 200);

      r.tick(14000); // 3 s of silence again
      expect(r.state.tunnelMode, isTrue);
      r.coast(fromMs: 14000, toMs: 17000);
      r.recoverAt(ms: 17200, northM: 400);

      expect(r.engine.sections.length, 2);
      expect(r.emitted.length, 2);
      final first = r.engine.sections.sections.first;
      final second = r.engine.sections.sections.last;
      expect(second.start.isAfter(first.end), isTrue,
          reason: 'oldest first, and sections cannot overlap');
    });

    test('10 · a large correction is flagged, per §16.1', () {
      final r = Rig()..driveIntoTunnel();
      // No motion samples at all, so the estimate contributes nothing and the
      // whole chord becomes residual.
      //
      // Dark long enough for 480 m to be physical (see test 06): at 20 m/s
      // entry the chord may imply up to 35 m/s, so 480 m needs >= 13.7 s.
      r.tick(12000);
      r.tick(20000);
      r.recoverAt(ms: 20200, northM: 500);

      final s = r.engine.sections.last!;
      expect(s.correctionMeters,
          greaterThan(AppConstants.largeReconcileMeters));
      expect(s.largeCorrection, isTrue,
          reason: '§16.1: "flag the event in the trip log"');
    });

    test('11 · a small correction is not flagged', () {
      final r = Rig()..driveIntoTunnel();
      r.coast(fromMs: 4100, toMs: 8000);
      r.recoverAt(ms: 8200, northM: 130, step: 10);

      final s = r.engine.sections.last!;
      expect(s.correctionMeters, lessThan(AppConstants.largeReconcileMeters));
      expect(s.largeCorrection, isFalse);
    });

    test('12 · reset clears the log with everything else', () {
      final r = Rig()..driveIntoTunnel();
      r.coast(fromMs: 4100, toMs: 8000);
      r.recoverAt(ms: 8200, northM: 200);
      expect(r.engine.sections.length, 1);

      r.engine.reset();
      expect(r.engine.sections.isEmpty, isTrue,
          reason: 'keeping it would leave the log spanning legs while the trip '
              'counters restarted');
    });
  });

  group('§15.3 · the log itself', () {
    EstimatedSection section(int n) => EstimatedSection(
          start: DateTime.utc(2026).add(Duration(minutes: n)),
          end: DateTime.utc(2026).add(Duration(minutes: n, seconds: 30)),
          estimatedMeters: 100.0 * n,
          heldSpeedMps: 20,
          correctionMeters: 5,
          largeCorrection: false,
        );

    test('13 · it is bounded, dropping the OLDEST first', () {
      final log = EstimatedSectionLog(capacity: 3);
      for (var i = 1; i <= 5; i++) {
        log.add(section(i));
      }
      expect(log.length, 3);
      expect(log.sections.first.estimatedMeters, 300.0,
          reason: 'the recent sections are the ones a co-driver questions');
      expect(log.last!.estimatedMeters, 500.0);
    });

    test('14 · totals aggregate what was estimated rather than measured', () {
      final log = EstimatedSectionLog()
        ..add(section(1))
        ..add(section(2));
      expect(log.totalEstimatedMeters, 300.0);
      expect(log.totalDuration, const Duration(seconds: 60));
    });

    test('15 · the exposed list cannot be mutated from outside', () {
      final log = EstimatedSectionLog()..add(section(1));
      expect(() => log.sections.add(section(2)), throwsUnsupportedError);
    });

    test('16 · the default capacity is generous enough for a real rally day',
        () {
      expect(AppConstants.maxLoggedSections, greaterThanOrEqualTo(200));
      expect(EstimatedSectionLog().capacity, AppConstants.maxLoggedSections);
    });
  });
}
