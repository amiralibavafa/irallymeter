// 24 test cases covering the TUNNEL HANDLING SYSTEM end to end.
//
// Coverage:
//   • ENGINE (8)      — normal GPS driving, tunnel entry on signal loss and on
//                       degraded accuracy, the cold-start guard, sensor
//                       estimation while dark, exit confirmation, and the
//                       double-count guard on recovery.
//   • SENSOR (6)      — anchoring to entry speed, non-negative distance, speed
//                       clamping, cornering removal, sign resolution, and
//                       gap handling.
//   • RECONCILE (5)   — undershoot correction, overshoot left alone, smooth
//                       payout with no visible jump, and time-free corrections.
//   • MANUAL (5)      — start/end markers, the worked example from the spec,
//                       the engine override, and negative-distance safety.
//
// The engine takes `now` explicitly rather than reading the clock, so every
// timing path here is deterministic — no waiting on real timers.

import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/constants/app_constants.dart';
import 'package:irallymeter/features/distance/domain/distance_delta.dart';
import 'package:irallymeter/features/distance/domain/distance_engine.dart';
import 'package:irallymeter/features/distance/domain/distance_reconciler.dart';
import 'package:irallymeter/features/distance/domain/longitudinal_axis_estimator.dart';
import 'package:irallymeter/features/distance/domain/motion_sample.dart';
import 'package:irallymeter/features/distance/domain/sensor_distance_source.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';

void main() {
  // ===========================================================================
  // ENGINE — source arbitration + the tunnel state machine
  // ===========================================================================
  group('TUNNEL · engine', () {
    test('01 · healthy GPS drives distance from the GPS source', () {
      final h = _Harness()
        ..gps(lat: 46.0, lon: 8.0, ms: 0) // anchors
        // +~55.6 m in 1 s ≈ 200 km/h. Fast, but inside the 90 m/s teleport
        // guard — a full 0.001° step in 1 s would (correctly) be rejected.
        ..gps(lat: 46.0005, lon: 8.0, ms: 1000);

      expect(h.deltas, hasLength(1));
      expect(h.deltas.single.source, DistanceSource.gps);
      expect(h.deltas.single.meters, closeTo(55.6, 3));
      expect(h.state.tunnelMode, isFalse);
    });

    test('02 · fixes simply stopping arrives as Tunnel Mode after the delay',
        () {
      final h = _Harness()
        ..gps(lat: 46.0, lon: 8.0, speed: 20, ms: 0)
        ..gps(lat: 46.0002, lon: 8.0, speed: 20, ms: 1000);

      // Still inside the confirm window — must not flap on a couple of skips.
      h.tick(ms: 2500);
      expect(h.state.tunnelMode, isFalse);

      h.tick(ms: 4100); // > 3 s since the last healthy fix (§15.1)
      expect(h.state.tunnelMode, isTrue);
      expect(h.state.source, DistanceSource.sensor);
    });

    test('03 · fixes that keep arriving but with junk accuracy also count as a '
        'tunnel', () {
      final h = _Harness()
        ..gps(lat: 46.0, lon: 8.0, speed: 20, ms: 0)
        ..gps(lat: 46.0002, lon: 8.0, speed: 20, ms: 1000);

      // A tunnel mouth often degrades accuracy before losing the fix entirely.
      // These arrive normally, so only the health test catches them.
      for (var t = 1500; t <= 3500; t += 500) {
        h.gps(lat: 46.0003, lon: 8.0, speed: 20, ms: t, acc: 80);
      }
      h.tick(ms: 3600);

      expect(h.state.tunnelMode, isTrue,
          reason: 'unusable fixes are no better than no fixes');
    });

    test('04 · a cold start with no signal never invents a tunnel', () {
      // No good fix has ever arrived → there is no entry speed to anchor an
      // estimate to. Waiting is the only honest answer.
      final h = _Harness()..tick(ms: 60000);

      expect(h.state.tunnelMode, isFalse);
      expect(h.deltas, isEmpty);
    });

    test('05 · distance keeps accruing from sensors while GPS is dark', () {
      final h = _Harness()..driveInto(tunnelAtMs: 4100, speedMps: 20);

      // 2 s of coasting at the 20 m/s entry speed ≈ 40 m.
      h.coast(fromMs: 4100, toMs: 6100);

      final sensor = h.deltas.where((d) => d.source == DistanceSource.sensor);
      expect(sensor, isNotEmpty);
      expect(h.state.tunnelMeters, closeTo(40, 4));
      expect(h.state.speedMps, closeTo(20, 1),
          reason: 'the estimate must hold the entry speed, not freeze or zero');
    });

    test('06 · a single reacquired fix does not end Tunnel Mode', () {
      final h = _Harness()..driveInto(tunnelAtMs: 4100, speedMps: 20);
      h.coast(fromMs: 4100, toMs: 5100);

      // Tunnel exits throw out a burst of plausible-but-wrong fixes.
      h.gps(lat: 46.002, lon: 8.0, speed: 20, ms: 5200);
      expect(h.state.tunnelMode, isTrue);
    });

    test('07 · sustained healthy fixes end Tunnel Mode', () {
      final h = _Harness()..driveInto(tunnelAtMs: 4100, speedMps: 20);
      h.coast(fromMs: 4100, toMs: 5100);

      h.gps(lat: 46.002, lon: 8.0, speed: 20, ms: 5200);
      h.gps(lat: 46.0021, lon: 8.0, speed: 20, ms: 6900);
      h.gps(lat: 46.0022, lon: 8.0, speed: 20, ms: 7900); // §15.2: 3 fixes

      expect(h.state.tunnelMode, isFalse);
      expect(h.state.source, DistanceSource.gps);
    });

    test('08 · the blackout chord is not integrated on top of the estimate',
        () {
      // The regression this guards: a short tunnel's entry/exit fix pair sits
      // INSIDE the stale-timeout window, so it looks like an ordinary (very
      // fast) increment and would be added a second time without re-anchoring.
      final h = _Harness()..driveInto(tunnelAtMs: 4100, speedMps: 20);
      h.coast(fromMs: 4100, toMs: 5100);

      final estimated = h.state.tunnelMeters;
      h.gps(lat: 46.002, lon: 8.0, speed: 20, ms: 5200);
      h.gps(lat: 46.0021, lon: 8.0, speed: 20, ms: 6900); // confirms exit

      final gpsAfterEntry = h.deltas
          .where((d) => d.source == DistanceSource.gps && d.timestamp.isAfter(h.at(3000)))
          .fold<double>(0, (a, d) => a + d.meters);

      expect(estimated, greaterThan(0));
      expect(gpsAfterEntry, lessThan(20),
          reason: 'the ~200 m blackout chord must not be re-integrated; only '
              'the small post-exit step and any correction may appear');
    });

    test('08b · a receiver that reports 0.0 for Doppler still seeds the tunnel',
        () {
      // THE FIX THIS PINS is `[SA-V3 11]`, which shipped reasoned and compiled
      // but unproven. This is that proof.
      //
      // Some receivers do not support Doppler and report `0.0` rather than null
      // or NaN — the Android emulator and, per `gps_providers.dart`, some real
      // chips. `hasValidDopplerSpeed` calls 0.0 VALID (it is finite and
      // non-negative), so the emit site used to publish 0.0 as the speed of a
      // pair whose positions had just moved 22 m in a second.
      //
      // On open road that costs nothing: distance comes from the positions. It
      // is the TUNNEL that fails, because `DistanceEngine` copies the emitted
      // speed into `_gpsSpeedMps` and SEEDS the estimator with it. Anchored at
      // zero, the estimate accrues nothing for the tunnel's whole length while
      // the cluster shows a confident 0 km/h — so on those devices the app
      // measured the open road correctly and then silently stopped measuring in
      // the one place this whole revision exists to handle.
      //
      // Every fix below carries `speed: 0` — the harness default is not relied
      // on, so a change to that default cannot quietly disarm this test.
      final h = _Harness()
        ..gps(lat: 46.0, lon: 8.0, speed: 0, ms: 0)
        ..gps(lat: 46.0002, lon: 8.0, speed: 0, ms: 1000) // ~22 m in 1 s
        ..gps(lat: 46.0004, lon: 8.0, speed: 0, ms: 2000)
        ..tick(ms: 5100); // > 3 s since the last healthy fix → Tunnel Mode

      expect(h.state.tunnelMode, isTrue, reason: 'precondition');
      expect(h.state.speedMps, closeTo(22, 3),
          reason: 'the entry speed must come from the positions when the '
              'receiver reports no usable Doppler; a 0.0 here is the bug');

      h.coast(fromMs: 5100, toMs: 7100); // 2 s at ~22 m/s ≈ 44 m

      expect(h.state.tunnelMeters, greaterThan(30),
          reason: 'seeded at zero the estimator accrues NOTHING, which is the '
              'failure: a whole tunnel measured as no distance at all');
    });
  });

  // ===========================================================================
  // SENSOR — the estimation fallback's guarantees
  // ===========================================================================
  group('TUNNEL · sensor fallback', () {
    test('09 · unseeded, it produces nothing', () {
      final s = SensorDistanceSource(LongitudinalAxisEstimator());
      expect(s.add(_motion(ms: 0)), isNull);
    });

    test('10 · with no confident axis it coasts at the entry speed', () {
      // Sign-blind acceleration is worse than none — it reads braking as
      // throttle. Coasting is the honest fallback.
      final s = SensorDistanceSource(LongitudinalAxisEstimator())
        ..seed(20, _t(0));

      var total = 0.0;
      for (var t = 250; t <= 2000; t += 250) {
        // Violent shaking, no learned axis → must not become distance.
        total += s.add(_motion(ms: t, ax: 30))?.meters ?? 0;
      }
      expect(s.speedMps, closeTo(20, 0.001));
      expect(total, closeTo(40, 1)); // 20 m/s × 2 s
    });

    test('11 · distance is never negative, even under hard braking', () {
      final s = SensorDistanceSource(_confidentAxis())..seed(20, _t(0));

      for (var t = 250; t <= 20000; t += 250) {
        final d = s.add(_motion(ms: t, ax: -30)); // slam on the brakes
        expect(d!.meters, greaterThanOrEqualTo(0));
        expect(d.speedMps, greaterThanOrEqualTo(0));
      }
      expect(s.speedMps, 0, reason: 'must settle at a clean stop, not negative');
    });

    test('12 · speed is clamped — an accelerometer spike cannot cause a jump',
        () {
      final s = SensorDistanceSource(_confidentAxis())..seed(20, _t(0));

      // Absurd sustained acceleration (pothole / phone knocked in its mount).
      for (var t = 250; t <= 30000; t += 250) {
        final d = s.add(_motion(ms: t, ax: 500))!;
        expect(d.speedMps, lessThanOrEqualTo(30.0 + 1e-6),
            reason: 'cap is max(v0*1.5, v0+8) = 30 m/s for a 20 m/s entry');
      }
    });

    test('13 · cornering is not mistaken for acceleration', () {
      // A steady turn: acceleration perpendicular to travel, at v·ω.
      final axis = _confidentAxis(); // forward ≈ +x
      final s = SensorDistanceSource(axis)..seed(20, _t(0));

      // ω = 0.25 rad/s about gravity (+z) → lateral accel = 20 × 0.25 = 5 m/s²,
      // pointing along +y (perpendicular to the +x forward axis).
      for (var t = 250; t <= 4000; t += 250) {
        s.add(_motion(ms: t, ay: 5.0, gz: 0.25));
      }
      expect(s.speedMps, closeTo(20, 0.5),
          reason: 'a bend must not read as acceleration');
    });

    test('14 · a stalled sensor stream re-anchors instead of inventing distance',
        () {
      final s = SensorDistanceSource(LongitudinalAxisEstimator())..seed(20, _t(0));

      // Backgrounded for 10 s. Integrating across that gap would fabricate
      // 200 m out of nothing.
      expect(s.add(_motion(ms: 10000)), isNull);
      // …and it recovers cleanly on the next in-window sample.
      expect(s.add(_motion(ms: 10250))!.meters, closeTo(5, 0.5));
    });
  });

  // ===========================================================================
  // RECONCILE — GPS recovery without a visible jump
  // ===========================================================================
  group('TUNNEL · reconciliation', () {
    test('15 · an undershoot against the chord is queued for correction', () {
      final r = DistanceReconciler()..add(150, _t(0));
      expect(r.isActive, isTrue);
      expect(r.remainingMeters, closeTo(150, 0.001));
    });

    test('16 · negligible residuals are ignored as noise', () {
      final r = DistanceReconciler()..add(0.2, _t(0));
      expect(r.isActive, isFalse);
    });

    test('17 · payout never exceeds the rate ceiling (no visible jump)', () {
      final r = DistanceReconciler()..add(150, _t(0)); // a large residual

      var last = _t(0);
      for (var t = 250; t <= 60000; t += 250) {
        final now = _t(t);
        final take = r.take(now);
        final dtSec = now.difference(last).inMilliseconds / 1000.0;
        last = now;
        expect(take, lessThanOrEqualTo(AppConstants.maxReconcileRateMps * dtSec + 1e-6),
            reason: 'a big residual must take LONGER, never arrive as a jump');
        expect(take, greaterThanOrEqualTo(0));
      }
    });

    test('18 · the full residual is eventually paid out, exactly once', () {
      final r = DistanceReconciler()..add(12, _t(0));

      var total = 0.0;
      for (var t = 250; t <= 60000; t += 250) {
        total += r.take(_t(t));
      }
      expect(total, closeTo(12, 0.01));
      expect(r.isActive, isFalse);
    });

    test('19 · a correction carries distance but no time (average stays honest)',
        () {
      final d = DistanceDelta.correction(timestamp: _t(0), meters: 5, speedMps: 20);
      expect(d.meters, 5);
      expect(d.dt, Duration.zero,
          reason: 'time already accrued during the tunnel; counting it again '
              'here would skew the average speed');
    });

    test('20a · a backgrounded app does not reconcile its way to phantom '
        'kilometres', () {
      // The app being suspended looks EXACTLY like a tunnel from the engine's
      // side: fixes stop, then resume somewhere else. Without a bound on how
      // long a "tunnel" may last, resuming after an hour of driving reconciles
      // the entire 50 km chord straight onto Trip A. Regression test for that.
      final h = _Harness()
        ..gps(lat: 46.0, lon: 8.0, speed: 20, ms: 0)
        ..gps(lat: 46.0002, lon: 8.0, speed: 20, ms: 1000);

      const hour = 3600000;
      h.tick(ms: hour); // resume — the engine notices the gap
      h.gps(lat: 46.45, lon: 8.0, speed: 20, ms: hour + 100); // ~50 km on
      h.gps(lat: 46.4502, lon: 8.0, speed: 20, ms: hour + 2000); // confirms

      // Drain any payout that might have been queued.
      for (var i = 0; i < 4000; i++) {
        h.tick(ms: hour + 2000 + i * 250);
      }

      final total = h.deltas.fold<double>(0, (a, d) => a + d.meters);
      expect(total, lessThan(100),
          reason: 'unmeasured distance is bad; invented distance is worse');
      expect(h.state.reconciling, isFalse);
    });

    test('20b · a genuine tunnel inside the duration bound still reconciles',
        () {
      // The suspension guard must not have disabled reconciliation outright.
      //
      // FIXTURE CORRECTED, ASSERTION UNCHANGED. This used to put the exit fix
      // 222 m from entry 1.1 s after the tunnel began — 202 m/s, or 727 km/h.
      // It passed only because the old code measured the blackout to the THIRD
      // confirming fix instead of to the first usable one, inflating the
      // duration until 202 m/s looked like 58. Both the CODEX-3 speed-history
      // guard and the CODEX-2 dark-end reconciliation correctly reject a
      // teleport, so the geometry has to be one a car could actually drive.
      //
      // 10 s dark at 20 m/s: the estimate coasts to ~200 m and the car really
      // travelled ~300 m, so there is a genuine ~100 m undershoot to correct
      // and the chord implies a perfectly ordinary 30 m/s.
      final h = _Harness()..driveInto(tunnelAtMs: 4100, speedMps: 20);
      h.coast(fromMs: 4100, toMs: 14100); // estimate ≈ 200 m

      // Exit ~300 m north of the entry fix → a real, provable undershoot.
      h.gps(lat: 46.002895, lon: 8.0, speed: 20, ms: 14200);
      h.gps(lat: 46.003000, lon: 8.0, speed: 20, ms: 15200);
      h.gps(lat: 46.003100, lon: 8.0, speed: 20, ms: 16200); // §15.2: 3 fixes

      expect(h.state.reconciling, isTrue,
          reason: 'a real tunnel undershoot must still be corrected');
    });

    test('20 · an overshoot past the chord is left alone', () {
      // The chord is a LOWER bound on road distance — a curved tunnel is always
      // longer than the line through it. Correcting down to it would eat real
      // distance, so an estimate above the chord must be left untouched.
      final h = _Harness()..driveInto(tunnelAtMs: 4100, speedMps: 30);
      h.coast(fromMs: 4100, toMs: 9100); // estimate ≈ 180 m

      // Exit only ~22 m from entry in a straight line (a hairpin tunnel).
      h.gps(lat: 46.0004, lon: 8.0, speed: 30, ms: 9200);
      h.gps(lat: 46.0005, lon: 8.0, speed: 30, ms: 10900);
      h.gps(lat: 46.0006, lon: 8.0, speed: 30, ms: 11900); // §15.2: 3 fixes

      expect(h.state.tunnelMode, isFalse);
      expect(h.state.reconciling, isFalse,
          reason: 'nothing is provable here, so nothing should be corrected');
    });
  });

  // ===========================================================================
  // MANUAL — driver-marked tunnels
  // ===========================================================================
  // SPEC-v2 §15 removed the manual Tunnel Start/End buttons outright:
  // "Requiring the driver or co-driver to press a button at the moment they
  // enter a tunnel is unrealistic in a moving car, and the resulting
  // measurement would depend on human reaction time." The tests that covered
  // that feature went with it in [3.4b] — they were not weakened, the feature
  // they exercised no longer exists. Automatic detection is covered by
  // estimation_thresholds_test.dart (§15.1/§15.2).
}

// =============================================================================
// Test helpers
// =============================================================================

final DateTime _base = DateTime(2024, 1, 1, 10, 0, 0);

DateTime _t(int ms) => _base.add(Duration(milliseconds: ms));

/// Drives a real [DistanceEngine], capturing everything it emits.
class _Harness {
  _Harness() {
    engine = DistanceEngine(
      onDelta: deltas.add,
      onState: (s) => state = s,
    );
  }

  late final DistanceEngine engine;
  final List<DistanceDelta> deltas = [];
  var state = _initialState;

  DateTime at(int ms) => _t(ms);

  void gps({
    required double lat,
    required double lon,
    double speed = 0,
    double acc = 4,
    required int ms,
  }) {
    engine.onGpsSample(
      GpsSample(
        timestamp: _t(ms),
        latitude: lat,
        longitude: lon,
        speedMps: speed,
        headingDeg: double.nan,
        accuracyM: acc,
        altitudeM: 0,
        hasFix: true,
      ),
      _t(ms),
    );
  }

  void tick({required int ms}) => engine.tick(_t(ms));

  /// Drive normally, then lose the signal and confirm Tunnel Mode.
  void driveInto({required int tunnelAtMs, required double speedMps}) {
    gps(lat: 46.0, lon: 8.0, speed: speedMps, ms: 0);
    gps(lat: 46.0002, lon: 8.0, speed: speedMps, ms: 1000);
    tick(ms: tunnelAtMs);
    expect(state.tunnelMode, isTrue, reason: 'harness precondition');
  }

  /// Feed quiet motion samples (no net acceleration) across a window.
  void coast({required int fromMs, required int toMs}) {
    for (var t = fromMs + 250; t <= toMs; t += 250) {
      engine.onMotionSample(_motion(ms: t), _t(t));
    }
  }
}

final _initialState = DistanceEngine(onDelta: (_) {}, onState: (_) {}).state;

/// A motion sample with the phone flat (gravity along +z).
MotionSample _motion({
  required int ms,
  double ax = 0,
  double ay = 0,
  double gz = 0,
}) =>
    MotionSample(
      timestamp: _t(ms),
      userAccel: Vec3(ax, ay, 0),
      gravity: const Vec3(0, 0, 9.81),
      gyro: Vec3(0, 0, gz),
    );

/// An axis estimator trained until it confidently points forward along +x.
LongitudinalAxisEstimator _confidentAxis() {
  final a = LongitudinalAxisEstimator();
  // Consistent votes converge; the EMA needs ~9 to clear the confidence floor.
  for (var i = 0; i < 40; i++) {
    a.observe(_motion(ms: i * 100, ax: 2.0), 2.0);
  }
  expect(a.isConfident, isTrue, reason: 'harness precondition');
  return a;
}


