// The payment path on the client: the deep link, the wire, and the flow.
//
// Everything here runs against a mocked HTTP boundary and a fake URL opener, so no
// browser and no gateway is ever touched — SPEC.md §4: "Mock the SMS provider and
// ZarinPal at the HTTP boundary. Never hit live gateways."
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:irallymeter/features/account/data/account_repository.dart';
import 'package:irallymeter/features/account/data/api_client.dart';
import 'package:irallymeter/features/account/data/deep_link_service.dart';
import 'package:irallymeter/features/account/data/device_identity.dart';
import 'package:irallymeter/features/account/data/secure_store.dart';
import 'package:irallymeter/features/account/domain/monotonic_clock.dart';
import 'package:irallymeter/features/account/domain/session.dart';
import 'package:irallymeter/features/account/presentation/account_flow_controller.dart';

import 'account_support.dart';

const String kSessionJson = '{'
    '"accessToken":"access-1","accessExpiresAt":"2026-09-08T12:15:00Z",'
    '"refreshToken":"refresh-1","refreshExpiresAt":"2026-10-08T12:00:00Z",'
    '"entitlement":null,"subscriptionExpiresAt":"2026-10-08T12:00:00Z"}';

void main() {
  // The deep-link tests drive a real MethodChannel, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PaymentCallback.tryParse', () {
    test('reads the shape INTERFACES.md §7 specifies', () {
      final PaymentCallback? cb = PaymentCallback.tryParse(
        'irallymeter://payment/callback?paymentId=pay-1&result=success',
      );
      expect(cb, isNotNull);
      expect(cb!.claimsSuccess, isTrue);
      expect(cb.paymentId, 'pay-1');
    });

    test('result=failed is read as a claim, not an error', () {
      final PaymentCallback? cb = PaymentCallback.tryParse(
        'irallymeter://payment/callback?result=failed&reason=PAYMENT_FAILED',
      );
      expect(cb!.claimsSuccess, isFalse);
    });

    test('⚠ refuses a link that is not ours', () {
      // A scheme we do not own must never reach the payment flow. `https://` here is
      // the interesting one: an attacker-supplied web link must not be able to drive
      // a session claim.
      for (final String hostile in <String>[
        'https://payment/callback?result=success',
        'irallymeter://settings?result=success',
        'not a uri at all ::::',
        'irallymeterx://payment/callback?result=success',
      ]) {
        expect(PaymentCallback.tryParse(hostile), isNull, reason: hostile);
      }
    });
  });

  group('the wire', () {
    late FakeSecureStore store;

    AccountRepository repoWith(
      Future<http.Response> Function(http.Request) handler, {
      List<String>? seenAuth,
    }) {
      store = FakeSecureStore()
        ..seed(SecureKeys.installationId, '3f2504e0-4f89-41d3-9a0c-0305e82c3301');
      final AccountApi api = AccountApi(
        baseUrl: 'https://api.example.invalid',
        client: MockClient((http.Request r) async {
          seenAuth?.add(r.headers['authorization'] ?? '');
          return handler(r);
        }),
      );
      return AccountRepository(
        store: store,
        api: api,
        identity: DeviceIdentity(store,
            deviceNameReader: () async => 'Pixel 7',
            platformOverride: 'android'),
        clock: MonotonicClock(store,
            wallClock: () => DateTime.utc(2026, 9, 8, 12)),
      );
    }

    test('⚠ verify-code surfaces the paymentToken, not just a userId', () async {
      // The regression guard for the bug that made payment unreachable: the client
      // must actually READ the token the backend now sends.
      final AccountRepository repo = repoWith((http.Request r) async =>
          http.Response(
            jsonEncode(<String, dynamic>{
              'next': 'PAYMENT_REQUIRED',
              'userId': 'u-1',
              'paymentToken': 'pay-token-1',
              'paymentTokenExpiresAt': '2026-09-08T12:30:00Z',
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          ));

      final VerifyCodeResult result = await repo.verifyCode(
          otpToken: 'otp', code: '123456', phone: '09121234567');
      expect(result.next, VerifyNext.paymentRequired);
      expect(result.paymentToken, 'pay-token-1');
    });

    test('startPayment sends the payment token as the bearer', () async {
      final List<String> auth = <String>[];
      final AccountRepository repo = repoWith(
        (http.Request r) async => http.Response(
          jsonEncode(<String, dynamic>{
            'paymentUrl': 'https://payment.zarinpal.com/pg/StartPay/A1',
            'authority': 'A1',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
        seenAuth: auth,
      );

      final PaymentStart start =
          await repo.startPayment(planCode: 'monthly', bearer: 'pay-token-1');
      expect(start.paymentUrl, contains('StartPay'));
      expect(auth.single, 'Bearer pay-token-1');
    });

    test('claim-session persists the session it receives', () async {
      final AccountRepository repo = repoWith((http.Request r) async =>
          http.Response(
            jsonEncode(<String, dynamic>{
              'next': 'SESSION',
              'session': jsonDecode(kSessionJson),
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          ));

      final VerifyCodeResult result = await repo.claimSession(
          paymentToken: 'pay-token-1', phone: '09121234567');
      expect(result.next, VerifyNext.session);
      // ⚠ The refresh token must land under its OWN key, written before the session
      // blob — a crash between the two would otherwise present an already-rotated
      // token on the next launch and the server would revoke the whole family.
      expect(store.snapshot[SecureKeys.refreshToken], 'refresh-1');
      expect(store.writes.first, SecureKeys.refreshToken);
    });

    test('plans are read as TOMAN and formatted without inventing a number',
        () async {
      final AccountRepository repo = repoWith((http.Request r) async =>
          http.Response(
            jsonEncode(<String, dynamic>{
              'plans': <dynamic>[
                <String, dynamic>{
                  'code': 'monthly',
                  'name': 'Monthly',
                  'priceToman': 400000,
                  'days': 30,
                },
              ],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          ));

      final List<Plan> plans = await repo.plans();
      expect(plans.single.priceToman, 400000);
      expect(plans.single.formattedToman, '400,000');
      // Never the Rial figure. The client does not multiply.
      expect(plans.single.formattedToman, isNot(contains('4,000,000')));
    });
  });

  group('the flow', () {
    late FakeSecureStore store;
    late List<Uri> opened;
    late List<String> paths;

    AccountFlowController controllerWith({
      required Map<String, Map<String, dynamic>> responses,
      DeepLinkService? deepLinks,
      void Function()? onAdmitted,
      bool openSucceeds = true,
    }) {
      opened = <Uri>[];
      paths = <String>[];
      store = FakeSecureStore()
        ..seed(SecureKeys.installationId, '3f2504e0-4f89-41d3-9a0c-0305e82c3301');
      final AccountApi api = AccountApi(
        baseUrl: 'https://api.example.invalid',
        client: MockClient((http.Request r) async {
          paths.add(r.url.path);
          final Map<String, dynamic>? body = responses[r.url.path];
          if (body == null) return http.Response('{}', 404);
          return http.Response(jsonEncode(body), 200,
              headers: <String, String>{'content-type': 'application/json'});
        }),
      );
      return AccountFlowController(
        AccountRepository(
          store: store,
          api: api,
          identity: DeviceIdentity(store,
              deviceNameReader: () async => 'Pixel 7',
              platformOverride: 'android'),
          clock: MonotonicClock(store,
              wallClock: () => DateTime.utc(2026, 9, 8, 12)),
        ),
        onAdmitted ?? () {},
        deepLinks: deepLinks,
        openUrl: (Uri url) async {
          opened.add(url);
          return openSucceeds;
        },
      );
    }

    Map<String, Map<String, dynamic>> paymentRequiredThen(
            Map<String, dynamic> claim) =>
        <String, Map<String, dynamic>>{
          '/auth/send-code': <String, dynamic>{
            'otpToken': 'otp-1',
            'expiresAt': '2026-09-08T12:15:00Z',
          },
          '/auth/verify-code': <String, dynamic>{
            'next': 'PAYMENT_REQUIRED',
            'userId': 'u-1',
            'paymentToken': 'pay-token-1',
          },
          '/plans': <String, dynamic>{'plans': <dynamic>[]},
          '/payment/start': <String, dynamic>{
            'paymentUrl': 'https://payment.zarinpal.com/pg/StartPay/A1',
            'authority': 'A1',
          },
          '/auth/claim-session': claim,
        };

    Future<AccountFlowController> atMembership(
      AccountFlowController c,
    ) async {
      await c.sendCode('09121234567');
      await c.submitCode('123456');
      expect(c.state.step, AccountStep.membership);
      return c;
    }

    test('PAYMENT_REQUIRED lands on membership and asks for prices', () async {
      final AccountFlowController c = controllerWith(
          responses: paymentRequiredThen(<String, dynamic>{}));
      await atMembership(c);
      await Future<void>.delayed(Duration.zero);
      expect(paths, contains('/plans'));
    });

    test('paying opens the gateway URL externally', () async {
      final AccountFlowController c = controllerWith(
          responses: paymentRequiredThen(<String, dynamic>{}));
      await atMembership(c);
      await c.startPayment('monthly');

      expect(opened.single.toString(),
          'https://payment.zarinpal.com/pg/StartPay/A1');
      expect(c.state.step, AccountStep.awaitingPayment);
    });

    test('a browser that will not open is a visible failure, not a dead button',
        () async {
      final AccountFlowController c = controllerWith(
        responses: paymentRequiredThen(<String, dynamic>{}),
        openSucceeds: false,
      );
      await atMembership(c);
      await c.startPayment('monthly');
      expect(c.state.step, AccountStep.membership);
      expect(c.state.error, isNotNull);
    });

    test('⚠ the deep link triggers a SERVER check, and its own verdict is ignored',
        () async {
      // The heart of it. The link says result=FAILED; the server says SESSION. The
      // server wins, because SPEC.md §4 makes it the sole authority and the link is a
      // wake-up signal only.
      bool admitted = false;
      final DeepLinkService links =
          DeepLinkService(channel: const MethodChannel('test/deeplink'));
      final AccountFlowController c = controllerWith(
        responses: paymentRequiredThen(<String, dynamic>{
          'next': 'SESSION',
          'session': jsonDecode(kSessionJson),
        }),
        deepLinks: links,
        onAdmitted: () => admitted = true,
      );
      await atMembership(c);
      await c.startPayment('monthly');

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'test/deeplink',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('link',
              'irallymeter://payment/callback?paymentId=p1&result=failed'),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);

      expect(paths, contains('/auth/claim-session'));
      expect(admitted, isTrue);
    });

    test('⚠ a payment the server has NOT seen returns to membership, not to the app',
        () async {
      // Holding a payment token is not evidence. If the server still answers
      // PAYMENT_REQUIRED the user must not be let in.
      bool admitted = false;
      final AccountFlowController c = controllerWith(
        responses: paymentRequiredThen(<String, dynamic>{
          'next': 'PAYMENT_REQUIRED',
          'userId': 'u-1',
          'paymentToken': 'pay-token-2',
        }),
        onAdmitted: () => admitted = true,
      );
      await atMembership(c);
      await c.startPayment('monthly');
      await c.checkPayment();

      expect(admitted, isFalse);
      expect(c.state.step, AccountStep.membership);
    });

    test('the manual "I have paid" button runs the same path as the link',
        () async {
      // It is a second first-class route, not a fallback: returning through the task
      // switcher fires no deep link at all.
      bool admitted = false;
      final AccountFlowController c = controllerWith(
        responses: paymentRequiredThen(<String, dynamic>{
          'next': 'SESSION',
          'session': jsonDecode(kSessionJson),
        }),
        onAdmitted: () => admitted = true,
      );
      await atMembership(c);
      await c.startPayment('monthly');
      await c.checkPayment();

      expect(admitted, isTrue);
      expect(store.snapshot[SecureKeys.refreshToken], 'refresh-1');
    });
  });
}
