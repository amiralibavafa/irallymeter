// The offline entitlement blob, verified in Dart.
//
// ⚠ THE FIRST GROUP IS THE ONE THAT MATTERS. Everything else in this file signs
// a blob in Dart and then verifies it in Dart, which proves the verifier is
// self-consistent and proves nothing about the backend. The `CROSS-LANGUAGE`
// group verifies a blob produced by the REAL backend signer
// (`irallymeter-api/src/auth/entitlement.ts`, jose, EdDSA) against the real
// public key that signed it. That is the only test here that would catch the
// two repos disagreeing about the bytes.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/features/account/domain/entitlement.dart';

/// Generated on 2026-09-08 by running the backend's own `EntitlementSigner`
/// under `tsx`, with a throwaway key pair. The private half was never written
/// to disk and is not needed to verify.
const String kBackendPublicKeyPem = '-----BEGIN PUBLIC KEY-----\n'
    'MCowBQYDK2VwAyEAsxkFlIURQzWtuc86Y/vz7xSfdrJYUnpmjQ5UdZvvY/8=\n'
    '-----END PUBLIC KEY-----';

/// sub=user-fixture-01 · did=3f2504e0-… · iat=2026-09-08T12:00Z ·
/// exp=2026-10-08T12:00Z
const String kBackendBlob =
    'eyJhbGciOiJFZERTQSJ9.eyJkaWQiOiIzZjI1MDRlMC00Zjg5LTQxZDMtOWEwYy0wMzA1ZTgy'
    'YzMzMDEiLCJzdWIiOiJ1c2VyLWZpeHR1cmUtMDEiLCJpYXQiOjE3ODg4Njg4MDAsImV4cCI6'
    'MTc5MTQ2MDgwMH0.WbaZEQLuUYl_8SN3KryleJ19dNI5jWTJPvnSgoHMXTj3XQWiVRpNqNqh'
    'u9jvzQu6QguubIMfHbSczX4yBeyzDQ';

const String kFixtureDeviceId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
final DateTime kFixtureIssuedAt = DateTime.utc(2026, 9, 8, 12);
final DateTime kFixtureExpiresAt = DateTime.utc(2026, 10, 8, 12);

void main() {
  group('CROSS-LANGUAGE — a blob the BACKEND signed', () {
    late EntitlementVerifier verifier;
    setUp(() => verifier = EntitlementVerifier.fromPem(kBackendPublicKeyPem));

    test('verifies, and yields the claims the backend put in it', () async {
      final EntitlementResult result = await verifier.verify(
        blob: kBackendBlob,
        deviceId: kFixtureDeviceId,
        now: kFixtureIssuedAt.add(const Duration(days: 1)),
      );

      expect(result.verdict, EntitlementVerdict.valid);
      expect(result.claims!.userId, 'user-fixture-01');
      expect(result.claims!.deviceId, kFixtureDeviceId);
      // Proves the epoch-seconds → DateTime conversion agrees with `jose`'s
      // `setIssuedAt`/`setExpirationTime`, which is the easiest thing to get
      // silently wrong by a factor of 1000.
      expect(result.claims!.issuedAt, kFixtureIssuedAt);
      expect(result.claims!.expiresAt, kFixtureExpiresAt);
    });

    test('is refused one second past its expiry', () async {
      final EntitlementResult result = await verifier.verify(
        blob: kBackendBlob,
        deviceId: kFixtureDeviceId,
        now: kFixtureExpiresAt.add(const Duration(seconds: 1)),
      );
      expect(result.verdict, EntitlementVerdict.expired);
    });

    test('is refused on a different handset', () async {
      // The blob is not a transferable licence. Copying it to another phone
      // has to fail, or the one-device rule is decorative offline.
      final EntitlementResult result = await verifier.verify(
        blob: kBackendBlob,
        deviceId: '00000000-0000-4000-8000-000000000000',
        now: kFixtureIssuedAt.add(const Duration(days: 1)),
      );
      expect(result.verdict, EntitlementVerdict.wrongDevice);
    });

    test(
        '⚠⚠ REGRESSION 1.0.1: a blob carrying the DB ROW ID instead of the '
        'installation UUID is refused', () async {
      // THE SHIPPED BUG, pinned from the client side.
      //
      // `irallymeter-api` signed the entitlement with `device.id` — the devices table
      // PRIMARY KEY — while this verifier compares `did` against the app's persistent
      // INSTALLATION UUID (`devices.device_id`). Both are uuids, so nothing looked
      // wrong; they are simply different columns on the same row.
      //
      // The consequence was not a visible error. The gate treats a blob that exists
      // and does not verify as a refusal, so every successful login, payment claim and
      // force-login was thrown away and the user was returned to the login screen —
      // three buttons that appeared completely dead while the server had already done
      // the work.
      //
      // The fixture blob's `did` IS the installation uuid, so verifying it against a
      // DIFFERENT uuid reproduces exactly what the device saw.
      const String dbRowPrimaryKey = '0c43ffad-9c93-41b5-a00b-44f7f50d40ff';
      expect(dbRowPrimaryKey, isNot(kFixtureDeviceId),
          reason: 'the two columns must differ or this proves nothing');

      final EntitlementResult result = await verifier.verify(
        blob: kBackendBlob,
        deviceId: dbRowPrimaryKey,
        now: kFixtureIssuedAt.add(const Duration(days: 1)),
      );

      expect(result.verdict, EntitlementVerdict.wrongDevice);
      expect(result.isValid, isFalse);
    });

    test('is refused when a single payload byte is changed', () async {
      final List<String> parts = kBackendBlob.split('.');
      final Map<String, dynamic> payload =
          jsonDecode(utf8.decode(_b64url(parts[1]))) as Map<String, dynamic>;
      // Grant ten more years to the same device — the exact edit an attacker
      // would make, and the one the signature exists to catch.
      payload['exp'] = (payload['exp'] as int) + 315360000;
      final String forged =
          '${parts[0]}.${_b64urlEncode(utf8.encode(jsonEncode(payload)))}.${parts[2]}';

      final EntitlementResult result = await verifier.verify(
        blob: forged,
        deviceId: kFixtureDeviceId,
        now: kFixtureIssuedAt.add(const Duration(days: 1)),
      );
      expect(result.verdict, EntitlementVerdict.badSignature);
    });
  });

  group('key loading', () {
    test('refuses a key that is not Ed25519', () {
      // A P-256 SPKI key is the same shape and would otherwise be silently
      // truncated to 32 meaningless bytes, failing every blob with no clue why.
      const String p256 = '-----BEGIN PUBLIC KEY-----\n'
          'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEo0LMPTeqBoyPMYFwvXOsg8OoDMPmr7ml\n'
          '2rWiJKlDzuQ0iBHFXA5MhtCgHM7JmCcAiIzRfKzvBOm/OpJn1DiJfw==\n'
          '-----END PUBLIC KEY-----';
      expect(() => EntitlementVerifier.fromPem(p256), throwsArgumentError);
    });

    test('refuses an empty key rather than accepting everything', () {
      expect(() => EntitlementVerifier.fromPem(''), throwsArgumentError);
    });
  });

  group('structure and algorithm', () {
    late _Signer signer;
    late EntitlementVerifier verifier;

    setUp(() async {
      signer = await _Signer.create();
      verifier = EntitlementVerifier(signer.publicKey);
    });

    test('a null blob is ABSENT, which is not a denial', () async {
      // DEVIATIONS.md D-2: the backend omits the blob whenever
      // ENTITLEMENT_PRIVATE_KEY is unset. Reading that as "not entitled" would
      // lock out a paying user on every environment without the key.
      final EntitlementResult result = await verifier.verify(
        blob: null,
        deviceId: kFixtureDeviceId,
        now: DateTime.utc(2026, 9, 8),
      );
      expect(result.verdict, EntitlementVerdict.absent);
      expect(result.isValid, isFalse);
    });

    test('an empty blob is ABSENT, not malformed', () async {
      final EntitlementResult result = await verifier.verify(
        blob: '',
        deviceId: kFixtureDeviceId,
        now: DateTime.utc(2026, 9, 8),
      );
      expect(result.verdict, EntitlementVerdict.absent);
    });

    test('garbage is MALFORMED rather than a crash', () async {
      for (final String junk in <String>['x', 'a.b', 'a.b.c.d', '...', '@.@.@']) {
        final EntitlementResult result = await verifier.verify(
          blob: junk,
          deviceId: kFixtureDeviceId,
          now: DateTime.utc(2026, 9, 8),
        );
        expect(
          result.verdict,
          anyOf(EntitlementVerdict.malformed, EntitlementVerdict.badSignature),
          reason: 'blob "$junk" must be refused, not thrown on',
        );
      }
    });

    test('⚠ alg:none is refused even with an empty signature', () async {
      // The classic JWT forgery. It is checked before the signature so a forged
      // header never reaches the verifier at all.
      final String blob = _compact(
        header: <String, dynamic>{'alg': 'none'},
        payload: <String, dynamic>{
          'sub': 'u',
          'did': kFixtureDeviceId,
          'iat': 1788868800,
          'exp': 1791460800,
        },
        signature: const <int>[],
      );
      final EntitlementResult result = await verifier.verify(
        blob: blob,
        deviceId: kFixtureDeviceId,
        now: kFixtureIssuedAt.add(const Duration(days: 1)),
      );
      expect(result.verdict, EntitlementVerdict.badSignature);
    });

    test('⚠ a TRUNCATED signature is refused, not thrown on', () async {
      // Found by falsification, not by design: `Ed25519.verify` THROWS on a
      // wrong-length signature rather than returning false. This verifier runs
      // at app start inside the gate, so an escaped exception here is a
      // handset that will not launch. `alg` is EdDSA, so the algorithm pin
      // does not catch this one — only the length check does.
      final String good = await signer.sign(<String, dynamic>{
        'sub': 'u',
        'did': kFixtureDeviceId,
        'iat': 1788868800,
        'exp': 1791460800,
      });
      final List<String> parts = good.split('.');
      final List<int> half = _b64url(parts[2]).sublist(0, 32);
      final String truncated =
          '${parts[0]}.${parts[1]}.${_b64urlEncode(half)}';

      final EntitlementResult result = await verifier.verify(
        blob: truncated,
        deviceId: kFixtureDeviceId,
        now: kFixtureIssuedAt.add(const Duration(days: 1)),
      );
      expect(result.verdict, EntitlementVerdict.badSignature);
    });

    test('a blob signed by a DIFFERENT key is refused', () async {
      final _Signer attacker = await _Signer.create();
      final String blob = await attacker.sign(<String, dynamic>{
        'sub': 'u',
        'did': kFixtureDeviceId,
        'iat': 1788868800,
        'exp': 1791460800,
      });
      final EntitlementResult result = await verifier.verify(
        blob: blob,
        deviceId: kFixtureDeviceId,
        now: kFixtureIssuedAt.add(const Duration(days: 1)),
      );
      expect(result.verdict, EntitlementVerdict.badSignature);
    });

    test('claims of the wrong TYPE are malformed, not coerced', () async {
      final String blob = await signer.sign(<String, dynamic>{
        'sub': 'u',
        'did': kFixtureDeviceId,
        'iat': '1788868800', // a string, not a number
        'exp': 1791460800,
      });
      final EntitlementResult result = await verifier.verify(
        blob: blob,
        deviceId: kFixtureDeviceId,
        now: kFixtureIssuedAt.add(const Duration(days: 1)),
      );
      expect(result.verdict, EntitlementVerdict.malformed);
    });

    test('a blob issued in the FUTURE is refused', () async {
      // What a rolled-back device clock looks like from inside the verifier.
      final String blob = await signer.sign(<String, dynamic>{
        'sub': 'u',
        'did': kFixtureDeviceId,
        'iat': kFixtureIssuedAt.millisecondsSinceEpoch ~/ 1000,
        'exp': kFixtureExpiresAt.millisecondsSinceEpoch ~/ 1000,
      });
      final EntitlementResult result = await verifier.verify(
        blob: blob,
        deviceId: kFixtureDeviceId,
        now: kFixtureIssuedAt.subtract(const Duration(days: 1)),
      );
      expect(result.verdict, EntitlementVerdict.notYetValid);
    });

    test('expiry is exclusive: exactly AT exp is refused', () async {
      final String blob = await signer.sign(<String, dynamic>{
        'sub': 'u',
        'did': kFixtureDeviceId,
        'iat': kFixtureIssuedAt.millisecondsSinceEpoch ~/ 1000,
        'exp': kFixtureExpiresAt.millisecondsSinceEpoch ~/ 1000,
      });
      expect(
        (await verifier.verify(
          blob: blob,
          deviceId: kFixtureDeviceId,
          now: kFixtureExpiresAt,
        ))
            .verdict,
        EntitlementVerdict.expired,
      );
      expect(
        (await verifier.verify(
          blob: blob,
          deviceId: kFixtureDeviceId,
          now: kFixtureExpiresAt.subtract(const Duration(seconds: 1)),
        ))
            .verdict,
        EntitlementVerdict.valid,
      );
    });
  });
}

// ── helpers ────────────────────────────────────────────────────────────────

/// Signs compact JWSs in Dart, so the structural tests do not depend on a
/// checked-in fixture for every case.
class _Signer {
  _Signer(this._keyPair, this.publicKey);

  static final Ed25519 _algorithm = Ed25519();

  final SimpleKeyPair _keyPair;
  final SimplePublicKey publicKey;

  static Future<_Signer> create() async {
    final SimpleKeyPair pair = await _algorithm.newKeyPair();
    return _Signer(pair, await pair.extractPublicKey());
  }

  Future<String> sign(Map<String, dynamic> payload) async {
    final String signingInput =
        '${_b64urlEncode(utf8.encode(jsonEncode(<String, dynamic>{'alg': 'EdDSA'})))}'
        '.${_b64urlEncode(utf8.encode(jsonEncode(payload)))}';
    final Signature sig = await _algorithm.sign(
      ascii.encode(signingInput),
      keyPair: _keyPair,
    );
    return '$signingInput.${_b64urlEncode(sig.bytes)}';
  }
}

String _compact({
  required Map<String, dynamic> header,
  required Map<String, dynamic> payload,
  required List<int> signature,
}) =>
    '${_b64urlEncode(utf8.encode(jsonEncode(header)))}'
    '.${_b64urlEncode(utf8.encode(jsonEncode(payload)))}'
    '.${_b64urlEncode(signature)}';

String _b64urlEncode(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<int> _b64url(String segment) {
  final int remainder = segment.length % 4;
  return base64Url
      .decode(remainder == 0 ? segment : segment + ('=' * (4 - remainder)));
}
