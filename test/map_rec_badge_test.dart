// The REC badge must follow the recorder, not the screen.
//
// This exists because of a bug I introduced and Saam caught by looking at the
// map: an offline-tiles banner was inserted BETWEEN `if (recording.recording)`
// and the badge it guarded, leaving
//
//     if (recording.recording)
//     if (_tilesFailed)
//       Positioned(...banner...),
//     const Positioned(...REC badge...),
//
// which is legal Dart and analyzes clean. Two failures, silently:
//   1. the REC badge became unconditional, so the map claimed to be recording
//      on a cold launch when nothing was;
//   2. the tiles-unavailable warning became reachable ONLY while recording,
//      so the one message that tells a driver the map is blind was hidden in
//      the common case.
//
// A false REC light is not cosmetic. It tells a crew their stage is being
// logged when it is not, and they find out after the stage.
//
// These drive the RECORDER, which is the thing the badge is supposed to
// reflect, rather than asserting on layout.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:irallymeter/core/di/providers.dart';
import 'package:irallymeter/core/storage/storage_service.dart';
import 'package:irallymeter/features/route_log/presentation/providers/route_log_providers.dart';

void main() {
  late Directory tempDir;
  late StorageService storage;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('irallymeter_rec');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    storage = await StorageService.init();
  });

  ProviderContainer makeContainer() {
    final c = ProviderContainer(
        overrides: [storageProvider.overrideWithValue(storage)]);
    addTearDown(c.dispose);
    return c;
  }

  group('MAP · REC state follows the recorder', () {
    test('01 · a cold start is NOT recording', () async {
      // The regression. Before the fix the badge ignored this entirely.
      final container = makeContainer();
      final state = container.read(routeRecorderProvider);

      expect(state.recording, isFalse,
          reason: 'nothing may claim to be recording until someone presses '
              'record — a false REC light tells a crew their stage is being '
              'logged when it is not');
      expect(state.points, isEmpty);
      expect(state.distanceMeters, 0);
    });

    test('02 · start() is what turns it on', () async {
      final container = makeContainer();
      container.read(routeRecorderProvider.notifier).start();

      expect(container.read(routeRecorderProvider).recording, isTrue);
    });

    test('03 · start() is idempotent and does not wipe a run in progress',
        () async {
      // Double-tapping record must not silently discard the track so far.
      final container = makeContainer();
      final notifier = container.read(routeRecorderProvider.notifier);
      notifier.start();
      final first = container.read(routeRecorderProvider);
      notifier.start();

      expect(identical(container.read(routeRecorderProvider), first), isTrue,
          reason: 'a second start() must be a no-op, not a reset');
    });

    test('04 · stopAndSave on an empty run records nothing and goes idle',
        () async {
      final container = makeContainer();
      final notifier = container.read(routeRecorderProvider.notifier);
      notifier.start();
      final saved = await notifier.stopAndSave();

      expect(saved, isNull,
          reason: 'an empty session must not be persisted as a real one');
      expect(container.read(routeRecorderProvider).recording, isFalse);
    });
  });
}
