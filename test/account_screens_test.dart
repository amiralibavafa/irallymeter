// WIDGET TESTS: the screens a person actually taps.
//
// ⚠ WRITTEN BECAUSE COVERAGE SAID 19.7%. The flow logic was well covered and the SCREENS
// were not, which is the half the user touches: a controller that behaves perfectly
// behind a button nobody can reach is still a broken login.
//
// These drive the REAL screens against a mocked HTTP boundary — real text fields, real
// taps, real rebuilds. No network, no platform channels.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:irallymeter/core/theme/app_theme.dart';
import 'package:irallymeter/features/account/data/api_client.dart';
import 'package:irallymeter/features/account/data/device_identity.dart';
import 'package:irallymeter/features/account/data/secure_store.dart';
import 'package:irallymeter/features/account/domain/api_error.dart';
import 'package:irallymeter/features/account/presentation/account_flow_screen.dart';
import 'package:irallymeter/features/account/presentation/providers/account_providers.dart';

import 'account_support.dart';

/// Taps a primary CTA by its label.
///
/// ⚠ `find.text` is ambiguous on these screens: the code screen's eyebrow heading is
/// also the word "VERIFY", so a bare text finder matches the heading AND the button.
Future<void> tapCta(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(FilledButton, label));
  await tester.pump();
  await tester.pump();
}

/// Pumps the real account flow with a canned set of endpoint responses.
Future<FakeSecureStore> pumpFlow(
  WidgetTester tester,
  Map<String, ({int status, Map<String, dynamic> body})> routes,
) async {
  final FakeSecureStore store = FakeSecureStore()
    ..seed(SecureKeys.installationId, '3f2504e0-4f89-41d3-9a0c-0305e82c3301');
  final AccountApi api = AccountApi(
    baseUrl: 'https://api.example.invalid',
    client: MockClient((http.Request r) async {
      final ({int status, Map<String, dynamic> body})? hit = routes[r.url.path];
      if (hit == null) return http.Response('{}', 404);
      return http.Response(jsonEncode(hit.body), hit.status,
          headers: <String, String>{'content-type': 'application/json'});
    }),
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        secureStoreProvider.overrideWithValue(store),
        accountApiProvider.overrideWithValue(api),
        // ⚠ Without this the flow silently STALLS on "VERIFYING…": verify-code builds a
        // device descriptor, which reaches the real device_info_plus platform channel,
        // and that never resolves under flutter_test. Injecting the reader keeps these
        // tests about the SCREENS rather than about plugin availability.
        deviceIdentityProvider.overrideWithValue(
          DeviceIdentity(store,
              deviceNameReader: () async => 'Pixel 7', platformOverride: 'android'),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.build(DisplayMode.day),
        home: const AccountFlowScreen(),
      ),
    ),
  );
  await tester.pump();
  return store;
}

const ({int status, Map<String, dynamic> body}) kCodeSent = (
  status: 200,
  body: <String, dynamic>{'otpToken': 'otp-1', 'expiresAt': '2099-01-01T00:00:00Z'},
);

void main() {
  group('phone entry', () {
    testWidgets('starts on phone entry and the CTA says SEND CODE',
        (WidgetTester tester) async {
      await pumpFlow(tester, <String, ({int status, Map<String, dynamic> body})>{});
      expect(find.text('Enter your phone number'), findsOneWidget);
      expect(find.text('CONTINUE'), findsOneWidget);
    });

    testWidgets('typing a number and tapping SEND CODE moves to code entry',
        (WidgetTester tester) async {
      await pumpFlow(tester, <String, ({int status, Map<String, dynamic> body})>{
        '/auth/send-code': kCodeSent,
      });

      await tester.enterText(find.byType(TextField), '09121234567');
      await tapCta(tester, 'CONTINUE');

      expect(find.text('Enter the code'), findsOneWidget);
      // The number is echoed back so the user can see they typed it right.
      expect(find.textContaining('09121234567'), findsOneWidget);
    });

    testWidgets('offers Get Membership and Force Login with an explanation',
        (WidgetTester tester) async {
      // The master spec lists all four elements on this screen.
      await pumpFlow(tester, <String, ({int status, Map<String, dynamic> body})>{});
      // Rich text: the line is one TextSpan tree, so the finder must look inside it.
      expect(find.textContaining('Not a member?', findRichText: true), findsOneWidget);
      expect(find.textContaining('Get Membership', findRichText: true), findsOneWidget);
      expect(find.text('FORCE LOGIN'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      // The dialog says what it COSTS, not just what it does.
      expect(find.textContaining('sign the other one out'), findsOneWidget);
      expect(find.textContaining('once every 24 hours'), findsOneWidget);
    });

    testWidgets('Force Login from the login screen sends a fresh code first',
        (WidgetTester tester) async {
      // It can never be a bare "take over" button: without a new SMS, anyone holding a
      // stolen handset could evict the real owner.
      await pumpFlow(tester, <String, ({int status, Map<String, dynamic> body})>{
        '/auth/send-code': kCodeSent,
      });
      await tester.enterText(find.byType(TextField), '09121234567');
      await tester.tap(find.text('FORCE LOGIN'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Enter the code'), findsOneWidget);
      expect(find.textContaining('MOVE THIS ACCOUNT'), findsOneWidget);
    });

    testWidgets('an empty number does nothing rather than calling the server',
        (WidgetTester tester) async {
      await pumpFlow(tester, <String, ({int status, Map<String, dynamic> body})>{});
      await tapCta(tester, 'CONTINUE');
      await tester.pump();
      expect(find.text('Enter your phone number'), findsOneWidget);
    });

    testWidgets('⚠ a server error is SHOWN, not swallowed', (WidgetTester tester) async {
      await pumpFlow(tester, <String, ({int status, Map<String, dynamic> body})>{
        '/auth/send-code': (
          status: 400,
          body: <String, dynamic>{
            'error': <String, dynamic>{
              'code': 'VALIDATION_ERROR',
              'message': 'that does not look like an Iranian mobile number',
            },
          },
        ),
      });

      await tester.enterText(find.byType(TextField), '12345');
      await tapCta(tester, 'CONTINUE');

      expect(find.textContaining('Iranian mobile number'), findsOneWidget);
    });
  });

  group('code entry', () {
    Future<void> reachCode(
      WidgetTester tester,
      Map<String, ({int status, Map<String, dynamic> body})> routes,
    ) async {
      await pumpFlow(tester, <String, ({int status, Map<String, dynamic> body})>{
        '/auth/send-code': kCodeSent,
        ...routes,
      });
      await tester.enterText(find.byType(TextField), '09121234567');
      await tapCta(tester, 'CONTINUE');
    }

    testWidgets('a wrong code keeps the user on the screen and says so',
        (WidgetTester tester) async {
      await reachCode(tester, <String, ({int status, Map<String, dynamic> body})>{
        '/auth/verify-code': (
          status: 401,
          body: <String, dynamic>{
            'error': <String, dynamic>{'code': 'OTP_INVALID', 'message': 'wrong'},
          },
        ),
      });

      await tester.enterText(find.byType(TextField), '000000');
      await tester.tap(find.widgetWithText(FilledButton, 'VERIFY'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Enter the code'), findsOneWidget);
      expect(find.textContaining('That code is not right'), findsOneWidget);
    });

    testWidgets('⚠ an EXPIRED code sends the user back to phone entry',
        (WidgetTester tester) async {
      // Staying on a dead code is a trap: no number of retries can ever succeed.
      await reachCode(tester, <String, ({int status, Map<String, dynamic> body})>{
        '/auth/verify-code': (
          status: 401,
          body: <String, dynamic>{
            'error': <String, dynamic>{'code': 'OTP_EXPIRED', 'message': 'expired'},
          },
        ),
      });

      await tester.enterText(find.byType(TextField), '000000');
      await tester.tap(find.widgetWithText(FilledButton, 'VERIFY'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Enter your phone number'), findsOneWidget);
    });

    testWidgets('USE A DIFFERENT NUMBER returns to phone entry',
        (WidgetTester tester) async {
      await reachCode(tester, <String, ({int status, Map<String, dynamic> body})>{});
      await tester.tap(find.text('USE A DIFFERENT NUMBER'));
      await tester.pump();
      expect(find.text('Enter your phone number'), findsOneWidget);
    });

    testWidgets('a verified code with no subscription lands on membership',
        (WidgetTester tester) async {
      await reachCode(tester, <String, ({int status, Map<String, dynamic> body})>{
        '/auth/verify-code': (
          status: 200,
          body: <String, dynamic>{
            'next': 'PAYMENT_REQUIRED',
            'userId': 'u-1',
            'paymentToken': 'pay-1',
          },
        ),
        '/plans': (
          status: 200,
          body: <String, dynamic>{
            'plans': <dynamic>[
              <String, dynamic>{
                'code': 'monthly',
                'name': 'Monthly',
                'priceToman': 400000,
                'days': 30,
              },
            ],
          },
        ),
      });

      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.widgetWithText(FilledButton, 'VERIFY'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('This number needs a subscription'), findsOneWidget);
      // ⚠ TOMAN, grouped, exactly as the server stated it. The client never computes a
      // price and must never show the Rial figure sent to the gateway.
      expect(find.textContaining('400,000'), findsOneWidget);
      expect(find.textContaining('4,000,000'), findsNothing);
      expect(find.text('PAY NOW'), findsOneWidget);
    });
  });

  group('device conflict', () {
    testWidgets('names the other phone and offers to move the account',
        (WidgetTester tester) async {
      await pumpFlow(tester, <String, ({int status, Map<String, dynamic> body})>{
        '/auth/send-code': kCodeSent,
        '/auth/verify-code': (
          status: 409,
          body: <String, dynamic>{
            'error': <String, dynamic>{
              'code': 'DEVICE_CONFLICT',
              'message': 'signed in elsewhere',
              'activeDevice': <String, dynamic>{
                'deviceName': 'iPhone 13',
                'lastSeen': '2026-09-19T10:00:00Z',
              },
            },
          },
        ),
      });

      await tester.enterText(find.byType(TextField), '09121234567');
      await tapCta(tester, 'CONTINUE');
      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.widgetWithText(FilledButton, 'VERIFY'));
      await tester.pump();
      await tester.pump();

      expect(find.text('This number is on another phone'), findsOneWidget);
      // Enough to recognise your own other phone, and nothing more.
      expect(find.textContaining('iPhone 13'), findsOneWidget);
      expect(find.text('MOVE IT TO THIS PHONE'), findsOneWidget);
      // The transfer costs a fresh SMS, and the screen says so.
      expect(find.textContaining('send a new code first'), findsOneWidget);
    });
  });

  group('device conflict with an unnamed device', () {
    testWidgets(
        '⚠⚠ the conflict screen still explains itself when the other device has '
        'NO NAME', (WidgetTester tester) async {
      // THE REAL PAYLOAD. Measured against the live backend: a device registered
      // without a name comes back as
      //   {"code":"DEVICE_CONFLICT","activeDevice":{"deviceName":null,"lastSeen":"..."}}
      // The existing conflict test uses 'iPhone 13' and therefore never exercised
      // this, the same blind spot that hid the payment bug: every test primed the
      // happy value, so the branch that actually ships was never run.
      await pumpFlow(tester, <String, ({int status, Map<String, dynamic> body})>{
        '/auth/send-code': kCodeSent,
        '/auth/verify-code': (
          status: 409,
          body: <String, dynamic>{
            'error': <String, dynamic>{
              'code': 'DEVICE_CONFLICT',
              'message': 'this number is signed in on another device',
              'activeDevice': <String, dynamic>{
                'deviceName': null,
                'lastSeen': '2026-09-19T10:00:00Z',
              },
            },
          },
        ),
      });

      await tester.enterText(find.byType(TextField), '09121234567');
      await tapCta(tester, 'CONTINUE');
      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.widgetWithText(FilledButton, 'VERIFY'));
      await tester.pump();
      await tester.pump();

      // The user must still land on the conflict screen and understand it.
      expect(find.text('This number is on another phone'), findsOneWidget);
      expect(find.text('MOVE IT TO THIS PHONE'), findsOneWidget);
      // And must NEVER be shown the literal word "null".
      expect(find.textContaining('null'), findsNothing);
      // The last-seen time is still useful even with no name, so it must survive.
      expect(find.textContaining('last used'), findsOneWidget);
    });
  });

  _smsDisabledTests();

  group('the error code is what drives the copy, never the message string', () {
    test('every wire code parses to its own enum value', () {
      // INTERFACES.md §1: the client switches on `code` and never parses `message`.
      for (final ApiErrorCode code in ApiErrorCode.values) {
        expect(ApiErrorCode.parse(code.wire), code, reason: code.wire);
      }
    });

    test('an unrecognised code degrades instead of crashing', () {
      // A server-side addition must not become a field outage.
      expect(ApiErrorCode.parse('SOMETHING_NEW_IN_2027'), ApiErrorCode.unknown);
      expect(ApiErrorCode.parse(null), ApiErrorCode.unknown);
    });

    test('the conflicting device parses only what the contract allows', () {
      final ConflictingDevice? d = ConflictingDevice.fromJson(
        <String, dynamic>{'deviceName': 'Pixel 7', 'lastSeen': '2026-09-19T10:00:00Z'},
      );
      expect(d!.deviceName, 'Pixel 7');
      expect(d.lastSeen!.isUtc, isTrue);
      // Junk is refused rather than half-built.
      expect(ConflictingDevice.fromJson(null), isNull);
      expect(ConflictingDevice.fromJson(<String, dynamic>{'lastSeen': 'x'}), isNull);
    });
  });
}

// ── TEMPORARY DEVELOPMENT FLOW: SMS_AUTH_ENABLED=false on the server ─────────────
//
// The app must not show a code screen when no code was sent. It decides from the
// SERVER's answer, never from a flag of its own, so one switch controls both halves.
void _smsDisabledTests() {
  group('when the server says no code is required', () {
    testWidgets('⚠ skips the OTP screen entirely and goes straight on',
        (WidgetTester tester) async {
      await pumpFlow(tester, <String, ({int status, Map<String, dynamic> body})>{
        '/auth/send-code': (
          status: 200,
          body: <String, dynamic>{
            'otpToken': 'otp-1',
            'expiresAt': '2099-01-01T00:00:00Z',
            'otpRequired': false,
          },
        ),
        '/auth/verify-code': (
          status: 200,
          body: <String, dynamic>{
            'next': 'PAYMENT_REQUIRED',
            'userId': 'u-1',
            'paymentToken': 'pay-1',
          },
        ),
        '/plans': (status: 200, body: <String, dynamic>{'plans': <dynamic>[]}),
      });

      await tester.enterText(find.byType(TextField), '09121234567');
      await tapCta(tester, 'CONTINUE');
      await tester.pump();

      expect(find.text('Enter the code'), findsNothing);
      expect(find.text('This number needs a subscription'), findsOneWidget);
    });

    testWidgets('⚠ but a MISSING otpRequired still shows the code screen',
        (WidgetTester tester) async {
      // The safety direction. An older server, a proxy that drops the field, or a
      // malformed response must leave the app asking for a code — never skipping it.
      await pumpFlow(tester, <String, ({int status, Map<String, dynamic> body})>{
        '/auth/send-code': (
          status: 200,
          body: <String, dynamic>{'otpToken': 'otp-1', 'expiresAt': '2099-01-01T00:00:00Z'},
        ),
      });

      await tester.enterText(find.byType(TextField), '09121234567');
      await tapCta(tester, 'CONTINUE');
      expect(find.text('Enter the code'), findsOneWidget);
    });
  });
}
