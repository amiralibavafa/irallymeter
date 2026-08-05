// C2 — the GNSS HEALTH "STREAM STALLS" counter could never move.
//
// `GpsHealthStats.noteStall()` existed and worked. It had ZERO call sites in
// `lib/`. The watchdog raised its `_StallSignal`, the service caught it and
// re-subscribed, and then emitted a plain `GpsSample.noFix()` — indistinguishable
// from the no-fix heartbeat a TUNNEL produces. Nothing told the health panel a
// stall had happened, so the field read 0 for every possible input.
//
// That matters more than a wrong number on a debug screen: `docs/ROAD-TEST.md`
// item 2 says STREAM STALLS must still read 0 after driving a real tunnel. It
// would have read 0 whatever happened, so that check could not fail and the
// road test would have "passed" on it.
//
// THE DISTINCTION IS THE WHOLE FEATURE, and it is what test 02 guards:
//   * tunnel  = silence with location services up throughout. Expected. Not a
//               stall, and must never be counted as one.
//   * stall   = silence that survived services going off and back on, so the
//               old subscription is dead and was rebuilt.
//
// Conflating them would make the counter fire on every tunnel, which is worse
// than it being stuck at zero: it would turn the road-test check into noise
// instead of an unfalsifiable pass.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/features/gps/domain/gps_health_stats.dart';
import 'package:irallymeter/features/gps/domain/gps_repository.dart';
import 'package:irallymeter/features/gps/domain/gps_sample.dart';
import 'package:irallymeter/features/gps/domain/gps_state.dart';
import 'package:irallymeter/features/gps/presentation/providers/gps_providers.dart';

void main() {
  final t0 = DateTime.fromMillisecondsSinceEpoch(0);

  group('C2 · STREAM STALLS counts stalls, and only stalls', () {
    test('01 · a stall is counted', () async {
      // THE REGRESSION. Before the fix nothing could produce a non-zero value
      // here, because the service emitted an unmarked no-fix sample.
      final h = GpsHealthStats();
      expect(h.stalls, 0);

      h.add(GpsSample.stalled(), t0);

      expect(h.stalls, 1,
          reason: 'the watchdog rebuilt a dead subscription and the health '
              'panel did not notice. ROAD-TEST item 2 reads this field, so a '
              'counter stuck at 0 makes that check unfalsifiable');
    });

    test('02 · a TUNNEL heartbeat is NOT counted as a stall', () async {
      // A tunnel is silence. This is the standing rule for this codebase and
      // the reason the flag exists rather than counting every no-fix sample.
      final h = GpsHealthStats();

      for (var i = 0; i < 20; i++) {
        h.add(GpsSample.noFix(), t0.add(Duration(seconds: i)));
      }

      expect(h.stalls, 0,
          reason: 'driving through a tunnel raised the stall count. That '
              'inverts ROAD-TEST item 2, which requires this to stay 0 THROUGH '
              'a tunnel');
      expect(h.noFixSamples, 20,
          reason: 'the tunnel gap must still be recorded as no-fix samples — '
              'it is just not a fault');
    });

    test('03 · stalls accumulate and do not disturb the other figures',
        () async {
      final h = GpsHealthStats();
      h.add(_fix(t0, acc: 5), t0);
      h.add(GpsSample.stalled(), t0.add(const Duration(seconds: 1)));
      h.add(_fix(t0.add(const Duration(seconds: 2)), acc: 5),
          t0.add(const Duration(seconds: 2)));
      h.add(GpsSample.stalled(), t0.add(const Duration(seconds: 3)));

      expect(h.stalls, 2);
      expect(h.fixes, 2, reason: 'a stall is not a fix');
    });

    test('04 · it reaches the panel through the REAL provider pipeline',
        () async {
      // The counter being right in isolation is not the bug. The bug was that
      // nothing connected it, so this drives the actual providers the screen
      // reads.
      final controller = StreamController<GpsSample>();
      final container = ProviderContainer(overrides: [
        gpsRepositoryProvider.overrideWithValue(_FakeGps(controller.stream)),
      ]);
      addTearDown(container.dispose);

      final sub = container.listen<AsyncValue<GpsState>>(
          gpsStateProvider, (_, __) {},
          fireImmediately: true);
      addTearDown(sub.close);

      controller.add(_fix(t0, acc: 5));
      await _pump();
      controller.add(GpsSample.stalled());
      await _pump();

      expect(container.read(gpsHealthProvider).stalls, 1,
          reason: 'the stall never reached gpsHealthProvider, which is exactly '
              'the wiring that was missing');
    });
  });
}

Future<void> _pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

GpsSample _fix(DateTime t, {double acc = 5}) => GpsSample(
      timestamp: t,
      latitude: 46.0,
      longitude: 8.0,
      speedMps: 10,
      headingDeg: 90,
      accuracyM: acc,
      altitudeM: 0,
      hasFix: true,
    );

class _FakeGps implements GpsRepository {
  _FakeGps(this._stream);
  final Stream<GpsSample> _stream;

  @override
  Stream<GpsSample> positionStream() => _stream;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<GpsSample?> lastKnown() async => null;
}
