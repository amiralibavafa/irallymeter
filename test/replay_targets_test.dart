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
    },
        // FAILS TODAY, BY DESIGN — measured 2555.451 m on first run.
        //
        // This is the §6.1 gap in `docs/GAP.md` (F2) reproduced with a number:
        // `GpsDistanceSource` rejects steps below a FIXED 1.0 m
        // (`app_constants.dart:45`), which an 8 m fix wanders past on almost
        // every sample. §6.1 requires the floor to be the fix's OWN accuracy,
        // plus a 1.5 m/s speed gate — neither exists yet.
        //
        // The assertion is deliberately left at full strength rather than
        // relaxed to the current behaviour. Step 3.2 implements §6.1 and
        // removes this skip; if it does not make this pass, 3.2 is not done.
        skip: 'unskipped by step 3.2 (§6.1 noise gating) — see docs/GAP.md F2');

    test('T3 · 2 km GPS-free section → error ≤ 3 %', () {
      final r = replay('tunnel_2km.jsonl');
      expect(r.enteredEstimationCount, 1,
          reason: 'the 80 s blackout must be detected exactly once');
      final estimated = r.metersBySource[DistanceSource.sensor] ?? 0;
      expect((estimated - 2000.0).abs() / 2000.0, lessThanOrEqualTo(0.03),
          reason: 'estimated ${estimated.toStringAsFixed(1)} m against a '
              'ground truth of 2000.0 m');
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
    },
        // FAILS TODAY, BY DESIGN — measured 16750 ms on first run.
        //
        // Confirms the D4 analysis in `docs/GAP.md`: it is the RATE CAP that
        // binds here, not the window. `reconcileWindow` is 5 s, so the window
        // is not what overran — `maxReconcileRateMps = 3.0`
        // (`app_constants.dart:108`) stretches the residual past 15 s on its
        // own. Raising the window to the spec's 15 s alone would not fix this
        // and would make it worse; the two constants have to be chosen
        // together, which is why 3.5 owns both.
        skip: 'unskipped by step 3.5 (§16.1 blending) — see docs/GAP.md D4');

    test('T6 · the full tunnel trace totals the real ground distance', () {
      final r = replay('tunnel_2km.jsonl');
      expect(r.errorFraction(3000.0), lessThanOrEqualTo(0.03),
          reason: 'measured ${r.totalMeters.toStringAsFixed(1)} m against a '
              'ground truth of 3000.0 m (500 clean + 2000 dark + 500 clean)');
    });
  });
}
