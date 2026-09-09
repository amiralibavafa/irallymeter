// The installation UUID, the app-version constant, and the monotonic clock.
//
// These three are the account layer's foundation: an unstable UUID silently
// breaks the one-device rule, a drifted version string misreports every login,
// and a clock that can go backwards hands out free subscriptions.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/features/account/data/device_identity.dart';
import 'package:irallymeter/features/account/data/secure_store.dart';
import 'package:irallymeter/features/account/domain/monotonic_clock.dart';

import 'account_support.dart';

void main() {
  group('installation UUID', () {
    test('is a well-formed v4 with the version and variant bits pinned', () async {
      // Not cosmetic: the server stores this as the device key, and a
      // generator that quietly emitted a v1 would leak a MAC address and a
      // timestamp into an identifier that is supposed to be random.
      final DeviceIdentity identity = DeviceIdentity(FakeSecureStore());
      final String id = await identity.installationId();

      expect(
        id,
        matches(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      );
      expect(id.length, 36);
    });

    test('is generated from Random.secure by default', () {
      // Falsifiable claim: a fixed seed must NOT reproduce it. If this ever
      // fails, the generator has been switched to a predictable Random and a
      // device id becomes guessable.
      final DeviceIdentity a = DeviceIdentity(FakeSecureStore());
      final DeviceIdentity b = DeviceIdentity(FakeSecureStore());
      expect(
        Future.wait<String>(<Future<String>>[
          a.installationId(),
          b.installationId(),
        ]).then((List<String> ids) => ids[0] == ids[1]),
        completion(isFalse),
      );
    });

    test('is written ONCE and is stable across every later read', () async {
      final FakeSecureStore store = FakeSecureStore();
      final DeviceIdentity identity = DeviceIdentity(store);

      final String first = await identity.installationId();
      final String second = await identity.installationId();
      final String third = await DeviceIdentity(store).installationId();

      expect(second, first);
      expect(third, first, reason: 'a fresh instance must read, not regenerate');
      expect(
        store.writes.where((String k) => k == SecureKeys.installationId).length,
        1,
        reason: 'rewriting on every read would churn the keystore',
      );
    });

    test('lands under the documented key', () async {
      final FakeSecureStore store = FakeSecureStore();
      final String id = await DeviceIdentity(store).installationId();
      expect(store.snapshot[SecureKeys.installationId], id);
    });

    test('a corrupt stored value is replaced, not trusted', () async {
      // Reaching here means the store was clobbered or written by an older
      // build. Handing the server a malformed id would fail every call with no
      // way for the user to recover.
      final FakeSecureStore store = FakeSecureStore(<String, String>{
        SecureKeys.installationId: 'not-a-uuid',
      });
      final String id = await DeviceIdentity(store).installationId();
      expect(id, isNot('not-a-uuid'));
      expect(
        id,
        matches(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      );
    });

    test('an uppercase but valid UUID is kept, not regenerated', () async {
      // A device that regenerated its id on a cosmetic difference would look
      // like a NEW handset to the server and would meet DEVICE_CONFLICT
      // against itself.
      const String stored = '3F2504E0-4F89-41D3-9A0C-0305E82C3301';
      final FakeSecureStore store = FakeSecureStore(<String, String>{
        SecureKeys.installationId: stored,
      });
      expect(await DeviceIdentity(store).installationId(), stored);
    });

    test('does not derive anything from the handset', () async {
      // SPEC.md §4: NEVER IMEI, NEVER IP-as-identity. Two identities built
      // with the same fake device name must still differ.
      Future<String> name() async => 'Pixel 7';
      final String a = await DeviceIdentity(FakeSecureStore(),
              deviceNameReader: name, platformOverride: 'android')
          .installationId();
      final String b = await DeviceIdentity(FakeSecureStore(),
              deviceNameReader: name, platformOverride: 'android')
          .installationId();
      expect(a, isNot(b));
    });
  });

  group('device descriptor', () {
    test('carries exactly the four fields INTERFACES.md §3 names', () async {
      final DeviceDescriptor d = await DeviceIdentity(
        FakeSecureStore(),
        deviceNameReader: () async => 'Pixel 7',
        platformOverride: 'android',
      ).describe();

      // A fifth field would be a contract change, and INTERFACES.md is
      // explicit that adding a field is a change.
      expect(d.toJson().keys.toSet(),
          <String>{'deviceId', 'platform', 'deviceName', 'appVersion'});
      expect(d.toJson()['platform'], 'android');
      expect(d.toJson()['deviceName'], 'Pixel 7');
    });
  });

  group('app version', () {
    test('⚠ kAppVersion has not drifted from pubspec.yaml', () {
      // The whole reason the constant is allowed to be hard-coded. If this
      // fails, do not edit the test — edit `kAppVersion` to match the pubspec.
      final String pubspec = File('pubspec.yaml').readAsStringSync();
      final RegExpMatch? match =
          RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec);
      expect(match, isNotNull, reason: 'pubspec.yaml has no version: line');
      expect(
        kAppVersion,
        match!.group(1),
        reason: 'kAppVersion in device_identity.dart must track pubspec.yaml',
      );
    });
  });

  group('MonotonicClock', () {
    test('returns the wall clock when nothing has been seen yet', () async {
      final FakeSecureStore store = FakeSecureStore();
      final DateTime wall = DateTime.utc(2026, 9, 8, 12);
      final MonotonicClock clock =
          MonotonicClock(store, wallClock: () => wall);

      expect(await clock.now(), wall);
      expect(store.snapshot[SecureKeys.clockMark], wall.toIso8601String());
    });

    test('⚠ a rolled-back wall clock loses to the stored mark', () async {
      // THE attack this class exists for. Without it, changing the date in
      // Settings restores an expired entitlement.
      final FakeSecureStore store = FakeSecureStore();
      DateTime wall = DateTime.utc(2026, 9, 20, 12);
      final MonotonicClock clock =
          MonotonicClock(store, wallClock: () => wall);

      final DateTime high = await clock.now();
      expect(high, DateTime.utc(2026, 9, 20, 12));

      wall = DateTime.utc(2026, 9, 1, 12); // user winds the clock back 19 days
      expect(
        await clock.now(),
        DateTime.utc(2026, 9, 20, 12),
        reason: 'the mark must win over a backwards wall clock',
      );
    });

    test('ratchets forward across ordinary offline use', () async {
      // The mark has to advance while the app is merely being USED offline,
      // or twenty days of driving would leave it pinned at the last server
      // contact and a rollback to day five would succeed.
      final FakeSecureStore store = FakeSecureStore();
      DateTime wall = DateTime.utc(2026, 9, 8, 12);
      final MonotonicClock clock =
          MonotonicClock(store, wallClock: () => wall);

      await clock.now();
      for (int day = 9; day <= 28; day++) {
        wall = DateTime.utc(2026, 9, day, 12);
        await clock.now();
      }
      expect(store.snapshot[SecureKeys.clockMark],
          DateTime.utc(2026, 9, 28, 12).toIso8601String());

      wall = DateTime.utc(2026, 9, 5, 12);
      expect(await clock.now(), DateTime.utc(2026, 9, 28, 12));
    });

    test('observe() adopts server time when it is ahead', () async {
      final FakeSecureStore store = FakeSecureStore();
      final MonotonicClock clock = MonotonicClock(
        store,
        wallClock: () => DateTime.utc(2026, 9, 8, 12),
      );

      await clock.observe(DateTime.utc(2026, 9, 19, 6));
      expect(await clock.now(), DateTime.utc(2026, 9, 19, 6));
    });

    test('observe() never moves the mark BACKWARDS', () async {
      // A stale or replayed server response must not be able to lower the
      // high-water mark, or the defence is undone by the network.
      final FakeSecureStore store = FakeSecureStore();
      final MonotonicClock clock = MonotonicClock(
        store,
        wallClock: () => DateTime.utc(2026, 9, 20, 12),
      );

      await clock.now();
      await clock.observe(DateTime.utc(2026, 9, 1, 0));
      expect(await clock.now(), DateTime.utc(2026, 9, 20, 12));
    });

    test('a corrupt mark degrades to the wall clock, never to a lockout',
        () async {
      // The mark can only ever make the client STRICTER, so losing it must
      // fail open. A user must not be locked out by a bad string.
      final FakeSecureStore store = FakeSecureStore(<String, String>{
        SecureKeys.clockMark: 'not-a-date',
      });
      final DateTime wall = DateTime.utc(2026, 9, 8, 12);
      expect(
        await MonotonicClock(store, wallClock: () => wall).now(),
        wall,
      );
    });

    test('normalises a local-time wall clock to UTC', () async {
      // Comparisons against `exp` are UTC. A local DateTime would compare
      // wrong by the timezone offset — 4.5 hours in Iran.
      final FakeSecureStore store = FakeSecureStore();
      final DateTime local = DateTime(2026, 9, 8, 12);
      final DateTime seen =
          await MonotonicClock(store, wallClock: () => local).now();
      expect(seen.isUtc, isTrue);
      expect(seen, local.toUtc());
    });
  });
}
