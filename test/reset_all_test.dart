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
      // resetTrip settles the reconciler first, because metres owed from before
      // a reset belong to the leg that is ending. If resetAll skipped that, a
      // post-tunnel balance would drip into the freshly zeroed counters over the
      // next seconds and "reset everything" would quietly not stay at zero.
      final container = makeContainer();
      final notifier = container.read(tripProvider.notifier);

      notifier.adjust(TripCounter.a, 5000);
      notifier.resetAll();
      final immediately = container.read(tripProvider);

      expect(immediately.tripA, 0);
      expect(immediately.tripB, 0);
      expect(immediately.odometer, 0,
          reason: 'anything left owing would reappear here');
      container.dispose();
    });
  });
}
