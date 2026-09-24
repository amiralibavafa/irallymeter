// The launch gate.
//
// ⚠ THE FIRST TEST IS THE ONE THAT PROTECTS THE PRODUCT. `SPEC.md` §4:
// "The rally computer must run with zero connectivity and must gain NO new API
// dependency. The speedometer never awaits a network call." The gate is the
// only new thing on the launch path, so it is the only thing that can break
// that. It is built here with an HTTP client that THROWS on every call.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:irallymeter/features/account/data/api_client.dart';
import 'package:irallymeter/features/account/data/secure_store.dart';
import 'package:irallymeter/features/account/domain/entitlement.dart';
import 'package:irallymeter/features/account/domain/monotonic_clock.dart';
import 'package:irallymeter/features/account/presentation/account_flow_screen.dart';
import 'package:irallymeter/features/account/presentation/account_gate.dart';
import 'package:irallymeter/features/account/presentation/providers/account_providers.dart';

import 'account_entitlement_test.dart'
    show kBackendBlob, kBackendPublicKeyPem, kFixtureDeviceId;
import 'account_support.dart';

/// Stands in for `IRallyMeterApp`. Finding it means the rally computer would
/// have been built; not finding it means it was not.
const Key kRallyComputer = Key('rally-computer');

/// An `http.Client` that refuses to do anything at all.
///
/// Not a mock returning an error response — a client that THROWS, so any
/// network call on the launch path surfaces as a test failure rather than as a
/// quietly handled offline state.
class _ExplodingClient extends http.BaseClient {
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls++;
    throw StateError(
      'THE GATE MADE A NETWORK CALL AT LAUNCH: '
      '${request.method} ${request.url}',
    );
  }
}

void main() {
  late FakeSecureStore store;
  late _ExplodingClient client;

  /// A session as the BACKEND actually serialises it: flat, with the
  /// entitlement blob at the top level. See `DEVIATIONS.md` D-3.
  String sessionJson({
    required String? entitlement,
    required String subscriptionExpiresAt,
  }) =>
      jsonEncode(<String, dynamic>{
        'accessToken': 'access-token',
        'accessExpiresAt': '2026-09-08T12:15:00.000Z',
        'refreshExpiresAt': subscriptionExpiresAt,
        'subscriptionExpiresAt': subscriptionExpiresAt,
        if (entitlement != null) 'entitlement': entitlement,
        'phone': '09121234567',
      });

  setUp(() {
    store = FakeSecureStore();
    client = _ExplodingClient();
  });

  Future<void> pumpGate(
    WidgetTester tester, {
    required DateTime wallClock,
    String baseUrl = 'https://api.example.invalid',
    String publicKeyPem = kBackendPublicKeyPem,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          secureStoreProvider.overrideWithValue(store),
          accountApiProvider.overrideWithValue(
            AccountApi(baseUrl: baseUrl, client: client),
          ),
          monotonicClockProvider.overrideWithValue(
            MonotonicClock(store, wallClock: () => wallClock),
          ),
          entitlementVerifierProvider.overrideWithValue(
            publicKeyPem.isEmpty
                ? null
                : EntitlementVerifier.fromPem(publicKeyPem),
          ),
        ],
        child: const AccountGate(
          child: MaterialApp(
            home: Scaffold(body: SizedBox.shrink(key: kRallyComputer)),
          ),
        ),
      ),
    );
    // One pump resolves the FutureProvider, one settles the frame it builds.
    await tester.pump();
    await tester.pump();
  }

  /// Seeds a session that the fixture blob is signed for.
  void seedValidSession() {
    store
      ..seed(SecureKeys.installationId, kFixtureDeviceId)
      ..seed(SecureKeys.refreshToken, 'refresh-token')
      ..seed(
        SecureKeys.session,
        sessionJson(
          entitlement: kBackendBlob,
          subscriptionExpiresAt: '2026-10-08T12:00:00.000Z',
        ),
      );
  }

  group('⚠⚠ REGRESSION 1.0.1 — entitlement bound to the wrong identifier', () {
    // WHAT THE USER ACTUALLY EXPERIENCED. The backend signed the blob with
    // `device.id` (the devices table PRIMARY KEY) while this app verifies `did`
    // against its INSTALLATION UUID. Every login, payment claim and force-login
    // succeeded server-side, saved a session, re-ran the gate — and the gate refused
    // the blob as "bound to another handset" and returned the login surface.
    //
    // Nothing crashed and nothing was logged, so three separate buttons looked
    // completely dead while the server had already done the work.

    testWidgets('a blob carrying the DB row id does NOT reach the rally computer',
        (WidgetTester tester) async {
      // The blob's `did` is kFixtureDeviceId; the handset reports the DB primary key
      // instead, which is exactly the mismatch that shipped.
      store
        ..seed(SecureKeys.installationId, '0c43ffad-9c93-41b5-a00b-44f7f50d40ff')
        ..seed(SecureKeys.refreshToken, 'refresh-token')
        ..seed(
          SecureKeys.session,
          sessionJson(
            entitlement: kBackendBlob,
            subscriptionExpiresAt: '2026-10-08T12:00:00.000Z',
          ),
        );

      await pumpGate(tester, wallClock: DateTime.utc(2026, 9, 20));

      // Refused, as designed — a bad blob must never be a fallback.
      expect(find.byKey(kRallyComputer), findsNothing);
      // ⚠ AND THE REFUSAL MUST BE VISIBLE. The failure mode being pinned is not
      // "denied", it is "denied silently": the user must land on a real screen they
      // can act on rather than a dead surface that looks like the tap did nothing.
      expect(find.byType(AccountFlowScreen), findsOneWidget);
    });

    testWidgets(
        '⇒ and once the entitlement carries the INSTALLATION UUID, the same flow '
        'admits', (WidgetTester tester) async {
      // The other half, without which the test above would pass just as happily if
      // the gate refused everything. This is the state the fixed backend produces.
      seedValidSession();

      await pumpGate(tester, wallClock: DateTime.utc(2026, 9, 20));

      expect(find.byKey(kRallyComputer), findsOneWidget);
    });
  });

  group('⚠ the offline invariant', () {
    testWidgets(
        'renders the rally computer with an HTTP client that throws on any call',
        (WidgetTester tester) async {
      seedValidSession();
      await pumpGate(tester, wallClock: DateTime.utc(2026, 9, 20));

      expect(find.byKey(kRallyComputer), findsOneWidget);
      expect(
        client.calls,
        0,
        reason: 'the launch path must not touch the network at all',
      );
    });

    testWidgets('admits with a live subscription and NO entitlement blob',
        (WidgetTester tester) async {
      // DEVIATIONS.md D-2: the backend legitimately omits the blob when it
      // starts without ENTITLEMENT_PRIVATE_KEY. Refusing here would lock out
      // a paying user on every environment that has not got the key yet.
      store
        ..seed(SecureKeys.installationId, kFixtureDeviceId)
        ..seed(SecureKeys.refreshToken, 'refresh-token')
        ..seed(
          SecureKeys.session,
          sessionJson(
            entitlement: null,
            subscriptionExpiresAt: '2026-10-08T12:00:00.000Z',
          ),
        );
      await pumpGate(tester, wallClock: DateTime.utc(2026, 9, 20));

      expect(find.byKey(kRallyComputer), findsOneWidget);
      expect(client.calls, 0);
    });
  });

  group('the gate refuses', () {
    testWidgets('with no stored session at all', (WidgetTester tester) async {
      await pumpGate(tester, wallClock: DateTime.utc(2026, 9, 20));

      expect(find.byKey(kRallyComputer), findsNothing);
      expect(find.text('Enter your phone number'), findsOneWidget);
    });

    testWidgets('⚠ so the GPS engine cannot start behind the login screen',
        (WidgetTester tester) async {
      // The whole reason the gate is a WRAPPER and not a route: the widget
      // that watches rawGpsStreamProvider (app.dart:29) is never built.
      await pumpGate(tester, wallClock: DateTime.utc(2026, 9, 20));
      expect(find.byKey(kRallyComputer), findsNothing);
    });

    testWidgets('when the blob is signed for ANOTHER handset',
        (WidgetTester tester) async {
      seedValidSession();
      store.seed(
          SecureKeys.installationId, '00000000-0000-4000-8000-000000000000');
      await pumpGate(tester, wallClock: DateTime.utc(2026, 9, 20));

      expect(find.byKey(kRallyComputer), findsNothing);
      expect(find.text('Enter your phone number'), findsOneWidget);
    });

    testWidgets('when the blob has expired', (WidgetTester tester) async {
      seedValidSession();
      await pumpGate(tester, wallClock: DateTime.utc(2026, 11, 1));
      expect(find.byKey(kRallyComputer), findsNothing);
    });

    testWidgets(
        '⚠ a LAPSED subscriber opens on membership, not on phone entry',
        (WidgetTester tester) async {
      // Master spec §"Expired User": they already know who they are, and the only
      // thing between them and the app is a payment. Sending them to phone entry
      // would make them prove their identity before being told the price.
      seedValidSession();
      await pumpGate(tester, wallClock: DateTime.utc(2026, 11, 1));
      await tester.pump();
      await tester.pump();

      expect(find.text('This number needs a subscription'), findsOneWidget);
      expect(find.text('PAY NOW'), findsOneWidget);
      expect(find.text('Enter your phone number'), findsNothing);
    });

    testWidgets('but someone who never signed in still starts at phone entry',
        (WidgetTester tester) async {
      // The distinction the `subscriptionExpired` flag exists to make.
      await pumpGate(tester, wallClock: DateTime.utc(2026, 9, 20));
      await tester.pump();
      expect(find.text('Enter your phone number'), findsOneWidget);
    });

    testWidgets('⚠ when the clock is rolled back below the high-water mark',
        (WidgetTester tester) async {
      // The mark carries the whole rollback defence, because the backend emits
      // no graceDays (DEVIATIONS.md D-1). Mark is set past the expiry, then the
      // device clock is wound back to a date the blob would still cover.
      seedValidSession();
      store.seed(
          SecureKeys.clockMark, DateTime.utc(2026, 11, 1).toIso8601String());
      await pumpGate(tester, wallClock: DateTime.utc(2026, 9, 20));

      expect(
        find.byKey(kRallyComputer),
        findsNothing,
        reason: 'winding the clock back must not restore an expired blob',
      );
    });

    testWidgets('when a corrupt blob is present rather than absent',
        (WidgetTester tester) async {
      // A blob that EXISTS and does not verify is a refusal, never a fallback
      // to the unsigned expiry — otherwise corrupting it would be the attack.
      store
        ..seed(SecureKeys.installationId, kFixtureDeviceId)
        ..seed(SecureKeys.refreshToken, 'refresh-token')
        ..seed(
          SecureKeys.session,
          sessionJson(
            entitlement: 'not.a.jws',
            subscriptionExpiresAt: '2026-10-08T12:00:00.000Z',
          ),
        );
      await pumpGate(tester, wallClock: DateTime.utc(2026, 9, 20));

      expect(find.byKey(kRallyComputer), findsNothing);
    });

    testWidgets('when the stored session JSON is corrupt',
        (WidgetTester tester) async {
      store
        ..seed(SecureKeys.refreshToken, 'refresh-token')
        ..seed(SecureKeys.session, '{not json');
      await pumpGate(tester, wallClock: DateTime.utc(2026, 9, 20));

      expect(find.byKey(kRallyComputer), findsNothing);
      expect(find.text('Enter your phone number'), findsOneWidget);
    });
  });

  group('build configuration', () {
    testWidgets('says so when no API base URL was compiled in',
        (WidgetTester tester) async {
      await pumpGate(tester, wallClock: DateTime.utc(2026, 9, 20), baseUrl: '');

      expect(find.text('BUILD NOT CONFIGURED'), findsOneWidget);
      expect(find.byKey(kRallyComputer), findsNothing);
    });

    testWidgets('falls back to the stored expiry with no public key',
        (WidgetTester tester) async {
      // A build with no key cannot verify, so it must not lock everyone out.
      seedValidSession();
      await pumpGate(
        tester,
        wallClock: DateTime.utc(2026, 9, 20),
        publicKeyPem: '',
      );
      expect(find.byKey(kRallyComputer), findsOneWidget);
    });
  });
}
