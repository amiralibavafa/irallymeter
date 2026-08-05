import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/features/distance/domain/distance_delta.dart';
import 'package:irallymeter/features/replay/domain/trace_event.dart';
import 'package:irallymeter/features/replay/domain/trace_player.dart';
import 'package:irallymeter/features/replay/domain/trace_recorder.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';

/// SPEC-v2 §19 accuracy targets, verified by replaying recorded traces into the
/// Distance Engine (§20.1).
///
/// "A build that does not meet these targets is not ready for release." These
/// are therefore assertions against committed fixtures with known ground truth,
/// not smoke tests — the numbers in the expectations come from how each fixture
/// was constructed (`tool/generate_fixtures.dart`), not from a previous run.
ReplayResult replay(String fixture) {
  final lines = File('test/fixtures/$fixture').readAsLinesSync();
  return TracePlayer().playLines(lines);
}

void main() {
  group('§20.1 · harness', () {
    test('01 · a GPS event round-trips through JSONL unchanged', () {
      const e = GpsTraceEvent(
        offsetMs: 1234,
        latitude: 35.6892,
        longitude: 51.389,
        speedMps: 23.6,
        speedAccuracyMps: 0.4,
        headingDeg: 90.0,
        accuracyM: 5.0,
        altitudeM: 1200.0,
        hasFix: true,
      );
      final back = TraceEvent.tryParse(e.toJsonLine()) as GpsTraceEvent;
      expect(back.offsetMs, 1234);
      expect(back.latitude, closeTo(35.6892, 1e-9));
      expect(back.speedMps, closeTo(23.6, 1e-9));
      expect(back.speedAccuracyMps, closeTo(0.4, 1e-9));
      expect(back.hasFix, isTrue);
    });

    test('02 · a non-finite Doppler speed survives the round trip as NaN', () {
      // JSON has no NaN. "The receiver reported nothing" must not silently
      // become "the receiver reported zero" — that is the D1 defect in
      // miniature, and the trace format must not reintroduce it.
      const e = GpsTraceEvent(
        offsetMs: 0,
        latitude: 0,
        longitude: 0,
        speedMps: double.nan,
        speedAccuracyMps: double.nan,
        headingDeg: double.nan,
        accuracyM: 5,
        altitudeM: 0,
        hasFix: true,
      );
      final back = TraceEvent.tryParse(e.toJsonLine()) as GpsTraceEvent;
      expect(back.speedMps.isNaN, isTrue);
      expect(back.speedAccuracyMps.isNaN, isTrue);
    });

    test('03 · comments, blanks and junk lines are skipped, not fatal', () {
      final events = TraceEvent.parseAll([
        '# header',
        '',
        '   ',
        'not json at all',
        '{"t":"unknown","ms":5}',
        '{"t":"gps","ms":10,"lat":1,"lon":2,"acc":5}',
      ]);
      expect(events, hasLength(1));
      expect(events.single.offsetMs, 10);
    });

    test('04 · a truncated trailing line does not lose the whole trace', () {
      // The recording most worth having is the one interrupted by a crash.
      final events = TraceEvent.parseAll([
        '{"t":"gps","ms":0,"lat":1,"lon":2,"acc":5}',
        '{"t":"gps","ms":1000,"lat":1.1,"lon":2,"ac',
      ]);
      expect(events, hasLength(1));
    });

    test('05 · the recorder is disabled by default and writes nothing', () {
      final out = <String>[];
      TraceRecorder(sink: out.add)
        ..start(DateTime.utc(2026))
        ..recordGps(GpsSample.noFix());
      expect(out, isEmpty,
          reason: 'recording a drive is opt-in; it must never self-start');
    });

    test('06 · an enabled recorder emits relative offsets', () {
      final out = <String>[];
      final t0 = DateTime.utc(2026, 1, 1, 12);
      final rec = TraceRecorder(sink: out.add, enabled: true)..start(t0);
      rec.recordGps(GpsSample(
        timestamp: t0.add(const Duration(milliseconds: 2500)),
        latitude: 1,
        longitude: 2,
        speedMps: 10,
        headingDeg: 0,
        accuracyM: 5,
        altitudeM: 0,
        hasFix: true,
      ));
      final gps = out.where((l) => !l.startsWith('#')).single;
      expect(TraceEvent.tryParse(gps)!.offsetMs, 2500);
    });
  });

  group('§19 · accuracy targets', () {
    test('T1 · 50 km good reception → error ≤ 1.0 %', () {
      final r = replay('clean_drive.jsonl');
      expect(r.wentBackwards, isFalse);
      expect(r.enteredEstimationCount, 0,
          reason: '1 Hz fixes must never look like a tunnel');
      expect(r.errorFraction(50000.0), lessThanOrEqualTo(0.010),
          reason: 'measured ${r.totalMeters.toStringAsFixed(1)} m '
              'against a ground truth of 50000.0 m');
    });

    test('T2 · 10 minutes parked → exactly 0.000 km accumulated', () {
      final r = replay('parked_10min.jsonl');
      // §19 states the target as 0.000 km, i.e. it must round to zero at the
      // three decimals the dashboard shows. Anything the co-driver can read is
      // a failure, so the tolerance is the display resolution, not a fudge.
      expect(r.totalMeters, lessThan(0.5),
          reason: 'accumulated ${r.totalMeters.toStringAsFixed(3)} m while '
              'stationary — the trip counter would visibly creep');
    });

    test('T3 · 2 km GPS-free section → error ≤ 3 %', () {
      final r = replay('tunnel_2km.jsonl');
      expect(r.enteredEstimationCount, 1,
          reason: 'the 80 s blackout must be detected exactly once');
      // ATTRIBUTION CHANGED IN [SA-V2 10], ACCURACY DID NOT.
      //
      // This used to require the SENSOR alone to produce ~2000 m, which was a
      // fair proxy while the estimator ran until §15.2 confirmed recovery three
      // fixes later. Codex's CODEX-2 fix stops the estimator the moment real
      // fixes return, so the last stretch of the blackout is now MEASURED and
      // reconciled instead of estimated: 1923.8 m estimated + 76.2 m
      // reconciled = exactly 2000 m, and the trip total for this fixture is
      // 3000.0 m against 3000.0 m of ground truth — zero error.
      //
      // So the co-driver-facing number is asserted first, and the estimator's
      // own contribution second. A regression where the estimator silently does
      // nothing still fails this, because the trip total would collapse.
      expect(r.errorFraction(3000.0), lessThanOrEqualTo(0.03),
          reason: 'the trip total is what a co-driver reads: '
              '${r.totalMeters.toStringAsFixed(1)} m against 3000.0 m');
      final estimated = r.metersBySource[DistanceSource.sensor] ?? 0;
      expect(estimated, greaterThanOrEqualTo(2000.0 * 0.95),
          reason: 'the estimator only produced '
              '${estimated.toStringAsFixed(1)} m of the 2000 m blackout — it '
              'is meant to carry the dark stretch until real fixes return, not '
              'to hand the whole thing to reconciliation');
    });

    test('T4 · recovery never moves the counters backwards', () {
      final r = replay('tunnel_2km.jsonl');
      expect(r.wentBackwards, isFalse,
          reason: 'SPEC-v2 §16.1: the trip counters must never move backwards, '
              'even if the estimate overshot');
    });

    test('T5 · a reconciliation completes within 15 s', () {
      final r = replay('tunnel_2km.jsonl');
      expect(r.maxReconcileGapMs, lessThanOrEqualTo(15000),
          reason: 'payout took ${r.maxReconcileGapMs} ms; §19 caps a recovery '
              'correction at 15 s');
    });

    test('T6 · the full tunnel trace totals the real ground distance', () {
      final r = replay('tunnel_2km.jsonl');
      expect(r.errorFraction(3000.0), lessThanOrEqualTo(0.03),
          reason: 'measured ${r.totalMeters.toStringAsFixed(1)} m against a '
              'ground truth of 3000.0 m (500 clean + 2000 dark + 500 clean)');
    });
  });

  // ===========================================================================
  // §12.2 inside a full replay — the case tunnel_2km structurally cannot cover
  // ===========================================================================
  //
  // tunnel_2km feeds `ax: 0.0` throughout, so the forward-axis estimator never
  // gains confidence and the sensor source correctly coasts at v₀. Everything
  // T3 proves is about §12.1. Until this fixture existed, §12.2's accelerometer
  // refinement had NEVER RUN in a full replay — only in isolated unit tests.
  //
  // tunnel_varying drives a car that genuinely slows down and speeds back up in
  // the dark, after an approach that varies enough to teach the axis estimator
  // which way is forward.
  group('§12.2 · the refinement, in a full replay', () {
    test('T8 · a varying-speed 80 s blackout stays inside §19\'s 3 %', () {
      final r = replay('tunnel_varying.jsonl');
      expect(r.enteredEstimationCount, 1,
          reason: 'the 80 s blackout must be detected exactly once');
      final estimated = r.metersBySource[DistanceSource.sensor] ?? 0;
      expect((estimated - 1700.0).abs() / 1700.0, lessThanOrEqualTo(0.03),
          reason: 'estimated ${estimated.toStringAsFixed(1)} m against a '
              'ground truth of 1700.0 m');
    });

    test('T8b · the refinement measurably beats coasting at v₀', () {
      // This is the test that gives §12.2 its reason to exist. The car enters
      // at 25 m/s and averages 21.25 m/s in the dark, so holding v₀ for the
      // whole 80 s would measure 2000 m against 1700 m of real travel — 17.6 %,
      // nearly six times §19's budget. If this ever stops passing, the
      // accelerometer path has silently stopped contributing and T8 alone would
      // not tell us.
      final r = replay('tunnel_varying.jsonl');
      final estimated = r.metersBySource[DistanceSource.sensor] ?? 0;
      const coasting = 2000.0;
      expect((estimated - 1700.0).abs(), lessThan((coasting - 1700.0).abs()),
          reason: 'estimated ${estimated.toStringAsFixed(1)} m is no better '
              'than coasting would have been (${coasting.toStringAsFixed(1)} m) '
              '— the refinement is not running');
    });

    test('T8c · a decelerating blackout still never runs the counters back',
        () {
      // The asymmetry that makes this worth its own test: the estimate ends up
      // ABOVE the truth here, and §16 corrects undershoot only.
      final r = replay('tunnel_varying.jsonl');
      expect(r.wentBackwards, isFalse);
    });

    test('T8d · the full varying trace totals the real ground distance', () {
      final r = replay('tunnel_varying.jsonl');
      expect(r.errorFraction(3050.0), lessThanOrEqualTo(0.03),
          reason: 'measured ${r.totalMeters.toStringAsFixed(1)} m against a '
              'ground truth of 3050.0 m (600 clean + 1700 dark + 750 clean)');
    });
  });
}
