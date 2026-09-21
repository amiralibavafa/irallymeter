// RELEASE 1.0 SIGNING IDENTITY — pinned.
//
// ⚠⚠ THIS TEST IS THE CONTRACT BETWEEN THE SERVER AND EVERY INSTALLED APK.
// The blob below was signed by the Release 1.0 PRIVATE key, which lives outside
// this repository and never leaves the server. The public key below is the half
// the app ships with. If someone regenerates the server key pair this test goes
// red, which is the only cheap warning that offline entitlement is about to
// break for every user already running the app: it fails in a valley, with no
// signal, where the user cannot be helped.
//
// If this fails, DO NOT regenerate anything to make it pass. Find out which key
// the server is actually using.
//
// The time is fixed so the assertion is about the SIGNATURE, not about today.
import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/features/account/domain/entitlement.dart';

const String kReleasePublicKeyPem = '''
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAkFniz2UkLRun98b3IhLmYM4dzwaQMQA9p7rhD5AotVg=
-----END PUBLIC KEY-----
''';

const String kBlobSignedByReleaseKey =
    'eyJhbGciOiJFZERTQSJ9.eyJkaWQiOiJyZWxlYXNlLTEtMC1jcm9zc2NoZWNrIiwic3ViIjoiMTExMTExMTEtMjIyMi0zMzMzLTQ0NDQtNTU1NTU1NTU1NTU1IiwiaWF0IjoxNzg5OTA1NjAwLCJleHAiOjE3OTI0OTc2MDB9.kfyhIvaIp-PkkdyCPV6J4wGXu2-iflkuOse5cf3_0Gr53X9ui3ZMrYWV86lRmn8SQofe-GgfOkjvaTHxWFyvCw';

void main() {
  group('Release 1.0 entitlement identity', () {
    test('the shipped PUBLIC key verifies a blob signed by the release PRIVATE key',
        () async {
      final EntitlementVerifier verifier =
          EntitlementVerifier.fromPem(kReleasePublicKeyPem);
      final EntitlementResult result = await verifier.verify(
        blob: kBlobSignedByReleaseKey,
        deviceId: 'release-1-0-crosscheck',
        now: DateTime.utc(2026, 9, 21),
      );
      expect(result.verdict, EntitlementVerdict.valid);
      expect(result.claims?.userId, '11111111-2222-3333-4444-555555555555');
    });

    test('a DIFFERENT key rejects the same blob — the control', () async {
      // Without this, the test above would pass just as happily if verification
      // accepted everything.
      final EntitlementVerifier other = EntitlementVerifier.fromPem('''
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAGb9ECWmEzf6FQbrBZ9w7lshQhqowtrbLDFw4rXAxZuE=
-----END PUBLIC KEY-----
''');
      final EntitlementResult result = await other.verify(
        blob: kBlobSignedByReleaseKey,
        deviceId: 'release-1-0-crosscheck',
        now: DateTime.utc(2026, 9, 21),
      );
      expect(result.verdict, isNot(EntitlementVerdict.valid));
    });
  });
}
