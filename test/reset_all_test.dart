// RST ALL — zero both trips AND the lifetime odometer.
//
// Road-test item 3, from Amirali's father: "touching the reset button must 0
// everything trip1 trip2 speed and ODO everything." Restated and confirmed a
// second time before it was built, because it is irreversible.
//
// TWO THINGS ABOUT THE REQUEST THAT DID NOT SURVIVE LITERAL READING, both
// deliberate and both recorded so neither reads as an oversight later:
//
//  1. It is a LONG PRESS, not a touch. The odometer is a lifetime total with no
//     undo anywhere, and C0 — the worst defect found in this app — was a plain
//     tap zeroing a single trip. Putting a wipe-everything action on a tap would
//     reintroduce C0 with a far larger blast radius. The button reads
//     "RST ALL / HOLD" so the gesture is discoverable rather than hidden, which
//     is the objection raised against the speed-unit toggle (C19).
//
//  2. "Speed" is the AVERAGE speed, not the speedometer. The live readout is a
//     GPS reading: zeroing it would blank the display for a fraction of a second
//     and the next fix would put the real value straight back. The average is an
//     accumulator like the trips, so it is the one that can be, and sensibly is,
//     cleared.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:irallymeter/core/di/providers.dart';
import 'package:irallymeter/core/storage/storage_service.dart';
import 'package:irallymeter/features/distance/domain/distance_delta.dart';
import 'package:irallymeter/features/trip/data/trip_repository.dart';
import 'package:irallymeter/features/trip/domain/trip_state.dart';
import 'package:irallymeter/features/trip/presentation/providers/trip_providers.dart';

void main() {
  late Directory tempDir;
  late StorageService storage;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('irallymeter_reset_all');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    // `resetAll` settles the reconciler, which touches the distance engine, and
    // that starts the real sensor streams. Silence the platform side so the
    // counters can be tested without a device.
    for (final ch in const [
      'dev.fluttercommunity.plus/sensors/method',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(ch), (call) async => null);
    }
    storage = await StorageService.init();
  });

  tearDownAll(() async => tempDir.delete(recursive: true));

  ProviderContainer makeContainer() => ProviderContainer(
        overrides: [storageProvider.overrideWithValue(storage)],
      );

  group('RST ALL · zeroes every counter', () {
    test('01 · trips AND the odometer all go to zero', () async {
      var container = makeContainer();

      // THE ODOMETER MUST BE GENUINELY NON-ZERO OR THIS TEST PROVES NOTHING.
      //
      // It was vacuous on the first attempt: `adjust` feeds the trips only and
      // nothing else in a unit test moves the lifetime total, so the assertion
      // "odometer == 0" passed against a build of `resetAll` that did not touch
      // the odometer at all. Caught by reverting the fix and finding the test
      // still green, which is the whole reason for falsifying rather than
      // trusting a pass.
      //
      // Seeding through the repository is the honest route: it is the same path
      // `build()` loads from, so the counter starts non-zero exactly as it would
      // on a phone that has been driven.
      await container.read(tripRepositoryProvider).save(
            const TripState(tripA: 1234, tripB: 567, odometer: 89000),
          );
      container.dispose();
      container = makeContainer();
      final notifier2 = container.read(tripProvider.notifier);

      expect(container.read(tripProvider).tripA, greaterThan(0),
          reason: 'precondition');
      expect(container.read(tripProvider).odometer, greaterThan(0),
          reason: 'PRECONDITION THAT MADE THIS TEST REAL — without a non-zero '
              'odometer the assertion below passes against a resetAll that '
              'never touches it');

      notifier2.resetAll();

      final after = container.read(tripProvider);
      expect(after.tripA, 0);
      expect(after.tripB, 0);
      expect(after.odometer, 0,
          reason: 'the odometer is the whole point of RST ALL. resetTrip has '
              'always left it alone, so a reset that spares it would be '
              'indistinguishable from the button that already existed');
      container.dispose();
    });

    test('02 · it survives a reload, so nothing drips back', () async {
      // THIS TEST WAS NAMED "survives a reload" AND NEVER RELOADED ANYTHING.
      // Codex caught it. It asserted against the in-memory state it had just
      // written, so a `resetAll` that never reached disk would have passed —
      // which is the same vacuous-precondition failure as test 01, in the same
      // file, found the same day.
      var container = makeContainer();
      await container.read(tripRepositoryProvider).save(
            const TripState(tripA: 5000, tripB: 900, odometer: 42000),
          );
      container.dispose();

      container = makeContainer();
      expect(container.read(tripProvider).odometer, greaterThan(0),
          reason: 'precondition: something to lose');

      await container.read(tripProvider.notifier).resetAll();
      container.dispose();

      // THE RELOAD THE NAME PROMISES. A fresh container reads from disk, so
      // this fails if resetAll returned before its write landed.
      container = makeContainer();
      final reloaded = container.read(tripProvider);
      expect(reloaded.tripA, 0);
      expect(reloaded.tripB, 0);
      expect(reloaded.odometer, 0,
          reason: 'the reset did not reach disk, so a restart resurrects the '
              'counters the crew believed they had cleared');
      container.dispose();
    });

    test('03 · a tunnel correction is persisted immediately', () async {
      // THE P1. Instant payout emits the whole residual in ONE delta and then
      // clears. Trip persistence is throttled to `tripPersistInterval` and only
      // re-triggers on further movement, so if the car stops at the tunnel
      // mouth that single correction can sit dirty and never reach disk. A
      // process kill then rolls the counters back to their pre-tunnel values
      // and the whole tunnel's distance is gone.
      //
      // The smooth payout hid this by emitting deltas for 15-60 s, one of which
      // would cross the interval. Making the payout instant removed that
      // accident, so the durability now has to be deliberate.
      var container = makeContainer();
      await container.read(tripRepositoryProvider).save(
            const TripState(tripA: 1000, tripB: 1000, odometer: 1000),
          );
      container.dispose();

      container = makeContainer();
      final notifier = container.read(tripProvider.notifier);

      // ARM THE THROTTLE FIRST, or this test proves nothing.
      //
      // `_lastPersist` starts at the epoch, so the FIRST delta of any kind
      // always clears the interval and persists. Without this line the
      // correction below is saved by accident and the test stays green with the
      // fix removed — which is exactly what happened on the first attempt, the
      // FIFTH vacuous pass in this codebase. One ordinary movement delta puts a
      // real timestamp on `_lastPersist` so the throttle is genuinely active
      // when the correction arrives, which is the state a car in a tunnel is in.
      notifier.debugApplyDelta(DistanceDelta(
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        meters: 10,
        dt: const Duration(seconds: 1),
        speedMps: 10,
        source: DistanceSource.gps,
        moving: true,
      ));

      // Drive a correction through the same entry point the engine uses: a
      // delta with dt == zero is what `DistanceDelta.correction` produces.
      notifier.debugApplyDelta(DistanceDelta.correction(
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        meters: 350,
        speedMps: 20,
      ));

      // READ THE DISK WITHOUT DISPOSING. This is the whole point and the second
      // thing that made this test vacuous: `ref.onDispose` flushes dirty state,
      // so a clean container teardown SAVES the correction and the test passes
      // against the defect. The failure Codex describes is a PROCESS KILL,
      // where no dispose ever runs — so the only honest check is what is on
      // disk right now, while the app is still notionally alive.
      final onDisk = TripRepository(storage).load();

      expect(onDisk.tripA, closeTo(1360, 1),
          reason: 'the correction that recovered a tunnel was still sitting '
              'dirty in memory. A process kill here loses the whole tunnel');
      container.dispose();
    });
  });
}
