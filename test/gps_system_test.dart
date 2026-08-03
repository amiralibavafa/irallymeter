// 20 test cases exercising the GPS SYSTEM end to end — accuracy-wise and
// speed-wise — through the real `gpsStateProvider` display pipeline.
//
// Coverage:
//   • SPEED  (9)  — Doppler preference, position-delta fallback, EMA smoothing,
//                   noise floor, convergence, decay-to-zero, outlier rejection,
//                   first-fix seeding, garbage-reading recovery.
//   • ACCURACY (8) — FixQuality classification bands, field fidelity
//                   (accuracy / lat / lon pass-through), and mid-stream dropout.
//   • HEADING (3) — course held while stationary, adopted + EMA-lagged while
//                   moving, and wrap-correct smoothing across the 0/360 seam.
//
// Every pipeline test feeds fixes through a fake GPS repository into the exact
// Riverpod providers that run on a phone, so behaviour is verified, not mocked.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/features/gps/domain/gps_repository.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';
import 'package:irallymeter/features/gps/domain/gps_state.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';

void main() {
  // ===========================================================================
  // SPEED — live display pipeline (gpsStateProvider)
  // ===========================================================================
  group('GPS · SPEED', () {
    test('01 · prefers the device-reported Doppler speed exactly', () async {
      // A single stationary pin reporting 20 m/s must read 20 m/s (seeded).
      final r = await _run([_fix(lat: 46.0, lon: 8.0, speed: 20, tMs: 1000)]);
      expect(r.last.smoothedSpeedMps, closeTo(20, 0.001));
    });

    test('02 · derives speed from position delta when no Doppler is reported',
        () async {
      // ~11.1 m north in 1 s ≈ 11.1 m/s — must not sit at 0.
      final r = await _run([
        _fix(lat: 46.0, lon: 8.0, speed: 0, tMs: 1000),
        _fix(lat: 46.0001, lon: 8.0, speed: 0, tMs: 2000),
      ]);
      expect(r.last.smoothedSpeedMps, greaterThan(0));
    });

    test('03 · floors sub-noise-floor speed to a clean 0 (no standstill jitter)',
        () async {
      // 0.2 m/s < 0.4 m/s floor → the big readout must show a hard 0.
      final r = await _run([_fix(lat: 46.0, lon: 8.0, speed: 0.2, tMs: 1000)]);
      expect(r.last.smoothedSpeedMps, 0);
    });

    test('04 · EMA lags a step change (output between old and new)', () async {
      final r = await _run([
        _fix(lat: 46.0, lon: 8.0, speed: 0, tMs: 1000), // seed at 0
        _fix(lat: 46.0, lon: 8.0, speed: 10, tMs: 2000), // step to 10 m/s
      ]);
      expect(r.last.smoothedSpeedMps, greaterThan(0));
      expect(r.last.smoothedSpeedMps, lessThan(10));
    });

    test('05 · converges to a sustained constant speed', () async {
      final fixes = [_fix(lat: 46.0, lon: 8.0, speed: 0, tMs: 0)]; // seed 0
      for (var i = 1; i <= 20; i++) {
        fixes.add(_fix(lat: 46.0, lon: 8.0, speed: 10, tMs: i * 1000));
      }
      final r = await _run(fixes);
      expect(r.last.smoothedSpeedMps, closeTo(10, 0.1));
    });

    test('06 · decays and snaps to exact 0 when the car stops', () async {
      final fixes = [_fix(lat: 46.0, lon: 8.0, speed: 10, tMs: 0)]; // seed 10
      for (var i = 1; i <= 15; i++) {
        fixes.add(_fix(lat: 46.0, lon: 8.0, speed: 0, tMs: i * 1000));
      }
      final r = await _run(fixes);
      expect(r.last.smoothedSpeedMps, 0);
    });

    test('07 · rejects an impossible teleport-derived speed (stays 0)',
        () async {
      // ~1113 m in 1 s ≈ 1113 m/s → a bad fix, not real movement.
      final r = await _run([
        _fix(lat: 46.0, lon: 8.0, speed: 0, tMs: 1000),
        _fix(lat: 46.01, lon: 8.0, speed: 0, tMs: 2000),
      ]);
      expect(r.last.smoothedSpeedMps, 0);
    });

    test('08 · first fix seeds the filter directly (no start-up lag)', () async {
      final r = await _run([_fix(lat: 46.0, lon: 8.0, speed: 15, tMs: 1000)]);
      expect(r.first.smoothedSpeedMps, closeTo(15, 0.001));
    });

    test('09 · recovers a real speed from movement despite a garbage Doppler',
        () async {
      // A negative/garbage Doppler value must fall back to position-delta, and
      // never surface as a negative speed.
      final r = await _run([
        _fix(lat: 46.0, lon: 8.0, speed: 0, tMs: 1000),
        _fix(lat: 46.0001, lon: 8.0, speed: -5, tMs: 2000), // ~11.1 m moved
      ]);
      expect(r.last.smoothedSpeedMps, greaterThan(0));
      expect(r.every((s) => s.smoothedSpeedMps >= 0), isTrue);
    });
  });

  // ===========================================================================
  // ACCURACY — fix-quality classification + field fidelity + dropout
  // ===========================================================================
  group('GPS · ACCURACY', () {
    test('10 · accuracy ≤ 8 m classifies as GOOD', () async {
      final r = await _run([_fix(lat: 46.0, lon: 8.0, acc: 6, tMs: 1000)]);
      expect(r.last.quality, FixQuality.good);
    });

    test('11 · 8 m < accuracy ≤ 25 m classifies as FAIR', () async {
      final r = await _run([_fix(lat: 46.0, lon: 8.0, acc: 15, tMs: 1000)]);
      expect(r.last.quality, FixQuality.fair);
    });

    test('12 · accuracy > 25 m classifies as POOR', () async {
      final r = await _run([_fix(lat: 46.0, lon: 8.0, acc: 40, tMs: 1000)]);
      expect(r.last.quality, FixQuality.poor);
    });

    test('13 · non-positive accuracy classifies as NONE', () async {
      final r = await _run([_fix(lat: 46.0, lon: 8.0, acc: 0, tMs: 1000)]);
      expect(r.last.quality, FixQuality.none);
    });

    test('14 · reported horizontal accuracy passes through untouched', () async {
      final r = await _run([_fix(lat: 46.0, lon: 8.0, acc: 12.5, tMs: 1000)]);
      expect(r.last.accuracyM, 12.5);
    });

    test('15 · position (lat/lon) passes through untouched', () async {
      final r = await _run([_fix(lat: 46.123, lon: 8.456, tMs: 1000)]);
      expect(r.last.latitude, closeTo(46.123, 1e-9));
      expect(r.last.longitude, closeTo(8.456, 1e-9));
    });

    test('16 · a weak fix stays POOR even with a strong speed reading',
        () async {
      final r = await _run([_fix(lat: 46.0, lon: 8.0, speed: 25, acc: 50, tMs: 1000)]);
      expect(r.last.quality, FixQuality.poor);
      expect(r.last.smoothedSpeedMps, closeTo(25, 0.001));
    });

    test('17 · a mid-stream dropout flips hasFix false and quality to NONE',
        () async {
      final r = await _run([
        _fix(lat: 46.0, lon: 8.0, speed: 10, acc: 5, tMs: 1000), // healthy
        GpsSample.noFix(), // dropout placeholder from the resilient stream
      ]);
      expect(r.last.hasFix, isFalse);
      expect(r.last.quality, FixQuality.none);
    });
  });

  // ===========================================================================
  // HEADING — course-over-ground accuracy (hold / adopt / wrap-safe EMA)
  // ===========================================================================
  group('GPS · HEADING', () {
    test('18 · heading is held (NaN) while effectively stationary', () async {
      // 0.2 m/s is below the noise floor → course must not be trusted.
      final r = await _run(
          [_fix(lat: 46.0, lon: 8.0, speed: 0.2, head: 90, tMs: 1000)]);
      expect(r.last.headingDeg.isNaN, isTrue);
    });

    test('19 · heading is adopted while moving and EMA-lags toward the new one',
        () async {
      final r = await _run([
        _fix(lat: 46.0, lon: 8.0, speed: 20, head: 0, tMs: 1000), // seed 0°
        _fix(lat: 46.0, lon: 8.0, speed: 20, head: 90, tMs: 2000), // turn to 90°
      ]);
      // alpha 0.2 → 0 + 0.2*90 = 18°, i.e. it lags, not snaps.
      expect(r.last.headingDeg, closeTo(18, 0.5));
      expect(r.last.headingDeg, lessThan(90));
    });

    test('20 · heading EMA wraps correctly across the 0/360 seam', () async {
      final r = await _run([
        _fix(lat: 46.0, lon: 8.0, speed: 20, head: 350, tMs: 1000),
        _fix(lat: 46.0, lon: 8.0, speed: 20, head: 10, tMs: 2000), // +20° across N
      ]);
      // Correct wrap → ~354°, NOT a naive average collapsing toward ~282°.
      expect(r.last.headingDeg, closeTo(354, 0.5));
      expect(r.last.headingDeg, greaterThan(340));
    });
  });
}

// =============================================================================
// Test helpers
// =============================================================================

/// Builds a GPS fix. Accuracy defaults to a healthy 4 m (well inside usable).
GpsSample _fix({
  required double lat,
  required double lon,
  double speed = 0,
  double head = double.nan,
  double acc = 4,
  required int tMs,
}) {
  return GpsSample(
    timestamp: DateTime.fromMillisecondsSinceEpoch(tMs),
    latitude: lat,
    longitude: lon,
    speedMps: speed,
    headingDeg: head,
    accuracyM: acc,
    altitudeM: 0,
    hasFix: true,
  );
}

/// Lets the Riverpod stream plumbing flush queued microtasks/events.
Future<void> _pump([int times = 5]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Fake GPS source that replays a caller-controlled stream of fixes.
class _FakeGps implements GpsRepository {
  _FakeGps(this._stream);
  final Stream<GpsSample> _stream;

  @override
  Future<bool> ensurePermission() async => true;
  @override
  Stream<GpsSample> positionStream() => _stream;
  @override
  Future<GpsSample?> lastKnown() async => null;
}

/// Feeds [fixes] through the real [gpsStateProvider] display pipeline and
/// returns the GpsState values it emitted (in order).
Future<List<GpsState>> _run(List<GpsSample> fixes) async {
  final controller = StreamController<GpsSample>();
  final container = ProviderContainer(overrides: [
    gpsRepositoryProvider.overrideWithValue(_FakeGps(controller.stream)),
  ]);
  addTearDown(container.dispose);

  final emitted = <GpsState>[];
  final sub = container.listen<AsyncValue<GpsState>>(
    gpsStateProvider,
    (_, next) {
      final v = next.valueOrNull;
      if (v != null) emitted.add(v);
    },
    fireImmediately: true,
  );
  addTearDown(sub.close);

  for (final f in fixes) {
    controller.add(f);
    await _pump();
  }
  await controller.close();
  await _pump();
  return emitted;
}
