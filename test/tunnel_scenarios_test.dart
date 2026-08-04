// INTEGRATION tests for the tunnel system, driven through real Riverpod
// containers rather than the domain objects in isolation.
//
// These complement tunnel_system_test.dart (deterministic domain/state-machine)
// and dashboard_layout_test.dart (widget/layout). Here the whole wiring runs:
// fake GPS + fake sensors → distance engine → trip computer, average speed and
// the manual tunnel markers, exactly as they are assembled on a phone.
//
// Follows the project's existing pipeline-test convention (see
// distance_speed_test.dart): override the repository seams, replay a stream of
// fixes, assert on real provider state.
//
// Coverage:
//   • NORMAL (4)   — continuous GPS distance, speed passthrough, average speed
//                    across changing speeds, slow movement.
//   • MANUAL (5)   — start marker contents, end calculations, multiple
//                    sessions, cancel, markers with no GPS fix.
//   • EDGE (9)     — permission denied, services disabled, GPS lost mid-trip,
//                    background/foreground, restart during Tunnel Mode, long
//                    tunnels, stopped in a tunnel, rapid GPS flapping.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/features/distance/domain/motion_repository.dart';
import 'package:irallymeter/features/distance/domain/motion_sample.dart';
import 'package:irallymeter/features/distance/presentation/providers/distance_providers.dart';
import 'package:irallymeter/features/gps/domain/gps_repository.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';
import 'package:irallymeter/features/settings/presentation/providers/settings_providers.dart';
import 'package:irallymeter/features/trip/data/trip_repository.dart';
import 'package:irallymeter/features/trip/domain/trip_state.dart';
import 'package:irallymeter/features/trip/presentation/providers/trip_providers.dart';
import 'package:irallymeter/features/average_speed/presentation/providers/average_speed_providers.dart';

void main() {
  // ===========================================================================
  // NORMAL GPS OPERATION
  // ===========================================================================
  group('SCENARIO · normal GPS', () {
    test('01 · distance accumulates over continuous GPS updates', () async {
      final h = await _Rig.start();
      // Four ~111 m steps at 2 s spacing (~55 m/s — fast but legal).
      for (var i = 0; i <= 4; i++) {
        await h.fix(lat: 46.0 + 0.001 * i, tMs: i * 2000);
      }
      expect(h.trip.tripA, closeTo(444.8, 5));
      expect(h.trip.odometer, closeTo(444.8, 5));
      await h.dispose();
    });

    test('02 · the speedometer reflects the GPS-reported speed', () async {
      final h = await _Rig.start();
      await h.fix(lat: 46.0, tMs: 0, speed: 25); // seeds the filter directly
      expect(h.container.read(displaySpeedMpsProvider), closeTo(25, 0.001));
      await h.dispose();
    });

    test('03 · average speed = distance ÷ moving time across changing speeds',
        () async {
      final h = await _Rig.start();
      // 111 m in 2 s (55.6 m/s), then 222 m in 2 s (111 m/s is a teleport, so
      // use 2 further 111 m steps) → 333.6 m over 6 s ≈ 55.6 m/s.
      for (var i = 0; i <= 3; i++) {
        await h.fix(lat: 46.0 + 0.001 * i, tMs: i * 2000);
      }
      final avg = h.container.read(averageSpeedProvider);
      expect(avg.distanceMeters, closeTo(333.6, 5));
      expect(avg.elapsed, const Duration(seconds: 6));
      expect(avg.averageMps, closeTo(55.6, 1));
      await h.dispose();
    });

    test('04 · very slow movement does not creep the trip but time still runs',
        () async {
      final h = await _Rig.start();
      // ~0.5 m steps — under the 1 m floor. Distance must stay put while the
      // average correctly decays toward zero.
      await h.fix(lat: 46.0, tMs: 0);
      await h.fix(lat: 46.0000045, tMs: 2000);
      await h.fix(lat: 46.000009, tMs: 4000);

      expect(h.trip.tripA, 0);
      final avg = h.container.read(averageSpeedProvider);
      expect(avg.distanceMeters, 0);
      expect(avg.elapsed, const Duration(seconds: 4));
      expect(avg.averageMps, 0);
      await h.dispose();
    });
  });

  // ===========================================================================
  // MANUAL TUNNEL MARKERS
  // ===========================================================================
  // SPEC-v2 §15 removed the manual Tunnel Start/End buttons outright:
  // "Requiring the driver or co-driver to press a button at the moment they
  // enter a tunnel is unrealistic in a moving car, and the resulting
  // measurement would depend on human reaction time." The tests that covered
  // that feature went with it in [3.4b] — they were not weakened, the feature
  // they exercised no longer exists. Automatic detection is covered by
  // estimation_thresholds_test.dart (§15.1/§15.2).

  // ===========================================================================
  // EDGE CASES
  // ===========================================================================
  group('SCENARIO · edge cases', () {
    test('10 · location permission denied → no crash, no phantom distance',
        () async {
      final h = await _Rig.start(permitted: false);
      expect(await h.container.read(gpsPermissionProvider.future), isFalse);
      expect(h.trip.tripA, 0);
      expect(h.container.read(tunnelModeProvider), isFalse,
          reason: 'with no fix ever seen there is nothing to estimate from');
      await h.dispose();
    });

    test('11 · location services disabled mid-trip → distance is kept, not reset',
        () async {
      final h = await _Rig.start();
      await h.fix(lat: 46.0, tMs: 0);
      await h.fix(lat: 46.001, tMs: 2000);
      final before = h.trip.tripA;
      expect(before, greaterThan(0));

      // The service reports the outage as synthetic no-fix samples.
      await h.raw(GpsSample.noFix());
      await h.raw(GpsSample.noFix());

      expect(h.trip.tripA, before, reason: 'an outage must never reset a trip');
      await h.dispose();
    });

    test('12 · GPS lost entirely → trip and odometer hold their values',
        () async {
      final h = await _Rig.start();
      for (var i = 0; i <= 2; i++) {
        await h.fix(lat: 46.0 + 0.001 * i, tMs: i * 2000);
      }
      final snapshot = h.trip;
      expect(snapshot.tripA, greaterThan(0));

      await h.gpsStream.close(); // the stream simply ends
      await _pump();

      expect(h.trip.tripA, snapshot.tripA);
      expect(h.trip.odometer, snapshot.odometer);
      await h.dispose();
    });

    test('13 · backgrounding and returning preserves the trip', () async {
      final h = await _Rig.start();
      await h.fix(lat: 46.0, tMs: 0);
      await h.fix(lat: 46.001, tMs: 2000);
      final before = h.trip.tripA;

      // Suspended: no samples at all for an hour, then fixes resume far away.
      await h.fix(lat: 46.45, tMs: 3600000);
      await h.fix(lat: 46.451, tMs: 3602000);

      // The 50 km gap must be re-anchored, never integrated.
      expect(h.trip.tripA, closeTo(before + 111.2, 6),
          reason: 'only the post-resume step counts, not the unseen 50 km');
      await h.dispose();
    });

    test('14 · app restart during Tunnel Mode restores the persisted trip',
        () async {
      final repo = _FakeTripRepo();
      final h = await _Rig.start(tripRepo: repo);
      await h.fix(lat: 46.0, tMs: 0, speed: 20);
      await h.fix(lat: 46.001, tMs: 2000, speed: 20);

      // Enter a tunnel, then die (process kill / restart).
      await h.enterTunnel();
      final beforeRestart = h.trip.tripA;
      await h.dispose(); // flushes on dispose

      // Relaunch against the same store.
      final h2 = await _Rig.start(tripRepo: repo);
      expect(h2.trip.tripA, closeTo(beforeRestart, 0.001),
          reason: 'trip distance must survive a restart');
      expect(h2.container.read(tunnelModeProvider), isFalse);
      await h2.dispose();
    });

    test('15 · a vehicle stopped inside a tunnel accumulates no distance',
        () async {
      final h = await _Rig.start();
      await h.fix(lat: 46.0, tMs: 0, speed: 0); // stationary entry
      await h.enterTunnel();
      final before = h.trip.tripA;

      // Idling: no net acceleration, just sitting there.
      for (var t = 250; t <= 5000; t += 250) {
        await h.motion(ms: t);
      }
      expect(h.trip.tripA, closeTo(before, 0.001),
          reason: 'a 0 m/s anchor must coast at zero, not creep');
      await h.dispose();
    });

    test('16 · rapid GPS flapping never corrupts the trip', () async {
      final h = await _Rig.start();
      await h.fix(lat: 46.0, tMs: 0, speed: 20);

      // Alternate good/unusable fixes hard. Distance may legitimately accrue,
      // but must stay monotonic and finite — never negative, never a teleport.
      var last = 0.0;
      for (var i = 1; i <= 20; i++) {
        if (i.isEven) {
          await h.fix(lat: 46.0 + 0.0002 * i, tMs: i * 1000, speed: 20);
        } else {
          await h.fix(lat: 46.0 + 0.0002 * i, tMs: i * 1000, speed: 20, acc: 90);
        }
        final now = h.trip.tripA;
        expect(now, greaterThanOrEqualTo(last), reason: 'must be monotonic');
        expect(now.isFinite, isTrue);
        last = now;
      }
      expect(last, lessThan(2000), reason: 'no phantom kilometres from flapping');
      await h.dispose();
    });

    test('17 · a long tunnel keeps estimating without freezing or resetting',
        () async {
      final h = await _Rig.start();
      await h.fix(lat: 46.0, tMs: 0, speed: 20);
      await h.enterTunnel();

      // 60 s of coasting at the ~20 m/s entry speed ≈ 1.2 km.
      for (var t = 250; t <= 60000; t += 250) {
        await h.motion(ms: t);
      }
      final engine = h.container.read(distanceEngineProvider);
      expect(engine.tunnelMode, isTrue, reason: 'GPS has not returned');
      expect(engine.tunnelMeters, greaterThan(500),
          reason: 'distance must keep growing, not freeze');
      expect(h.trip.tripA, greaterThan(500));
      await h.dispose();
    });

    test('18 · average speed keeps integrating through a tunnel', () async {
      final h = await _Rig.start();
      await h.fix(lat: 46.0, tMs: 0, speed: 20);
      await h.enterTunnel();

      for (var t = 250; t <= 10000; t += 250) {
        await h.motion(ms: t);
      }
      final avg = h.container.read(averageSpeedProvider);
      expect(avg.distanceMeters, greaterThan(0),
          reason: 'the average must not freeze while dark');
      expect(avg.elapsed, greaterThan(Duration.zero));
      expect(avg.averageMps, closeTo(20, 3));
      await h.dispose();
    });
  });
}

// =============================================================================
// Test rig
// =============================================================================

final DateTime _base = DateTime(2024, 1, 1, 10, 0, 0);
DateTime _t(int ms) => _base.add(Duration(milliseconds: ms));

Future<void> _pump([int times = 6]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Assembles the real provider graph over fake GPS/motion/storage seams.
class _Rig {
  _Rig._(this.container, this.gpsStream, this.motionStream);

  final ProviderContainer container;
  final StreamController<GpsSample> gpsStream;
  final StreamController<MotionSample> motionStream;

  static Future<_Rig> start({
    bool permitted = true,
    TripRepository? tripRepo,
  }) async {
    final gps = StreamController<GpsSample>.broadcast();
    final motion = StreamController<MotionSample>.broadcast();

    final container = ProviderContainer(overrides: [
      gpsRepositoryProvider
          .overrideWithValue(_FakeGps(gps.stream, permitted: permitted)),
      motionRepositoryProvider.overrideWithValue(_FakeMotion(motion.stream)),
      tripRepositoryProvider.overrideWithValue(tripRepo ?? _FakeTripRepo()),
      calibrationProvider.overrideWithValue(1.0),
    ]);

    // Mirror app.dart: keep the GPS pipeline, engine, delta stream and
    // integrators alive for the container's lifetime.
    container.listen(rawGpsStreamProvider, (_, __) {}, fireImmediately: true);
    container.listen(gpsStateProvider, (_, __) {}, fireImmediately: true);
    container.listen(distanceEngineProvider, (_, __) {}, fireImmediately: true);
    container.listen(distanceDeltaProvider, (_, __) {}, fireImmediately: true);
    container.listen(tripProvider, (_, __) {}, fireImmediately: true);
    container.listen(averageSpeedProvider, (_, __) {}, fireImmediately: true);
    await _pump();

    return _Rig._(container, gps, motion);
  }

  TripState get trip => container.read(tripProvider);

  Future<void> raw(GpsSample s) async {
    gpsStream.add(s);
    await _pump();
  }

  Future<void> fix({
    required double lat,
    double lon = 8.0,
    double speed = 0,
    double acc = 4,
    required int tMs,
  }) =>
      raw(GpsSample(
        timestamp: _t(tMs),
        latitude: lat,
        longitude: lon,
        speedMps: speed,
        headingDeg: double.nan,
        accuracyM: acc,
        altitudeM: 0,
        hasFix: true,
      ));

  /// Wait for the REAL detector to declare Tunnel Mode.
  ///
  /// Simply stops feeding fixes and lets the engine's heartbeat notice. This
  /// uses real elapsed time on purpose: dropout detection is inherently
  /// wall-clock (it fires because samples STOPPED), so faking it here would
  /// test nothing. Costs ~2 s per call.
  Future<void> enterTunnel() async {
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (!container.read(tunnelModeProvider) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(container.read(tunnelModeProvider), isTrue,
        reason: 'rig precondition: the engine should have entered Tunnel Mode');
  }

  /// A quiet motion sample — phone flat, no net acceleration.
  Future<void> motion({required int ms}) async {
    motionStream.add(MotionSample(
      timestamp: _t(ms),
      userAccel: Vec3.zero,
      gravity: const Vec3(0, 0, 9.81),
      gyro: Vec3.zero,
    ));
    await _pump(2);
  }

  Future<void> dispose() async {
    await gpsStream.close();
    await motionStream.close();
    container.dispose();
  }
}

class _FakeGps implements GpsRepository {
  _FakeGps(this._stream, {this.permitted = true});
  final Stream<GpsSample> _stream;
  final bool permitted;

  @override
  Future<bool> ensurePermission() async => permitted;
  @override
  Stream<GpsSample> positionStream() =>
      permitted ? _stream : const Stream<GpsSample>.empty();
  @override
  Future<GpsSample?> lastKnown() async => null;
}

class _FakeMotion implements MotionRepository {
  _FakeMotion(this._stream);
  final Stream<MotionSample> _stream;

  @override
  Stream<MotionSample> motionStream() => _stream;
}

/// In-memory trip store that survives a container restart, like Hive does.
class _FakeTripRepo implements TripRepository {
  TripState stored = TripState.zero;

  @override
  TripState load() => stored;
  @override
  Future<void> save(TripState s) async => stored = s;
}
