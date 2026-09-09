import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// The result of asking "may this device run right now, with no network?".
///
/// A sealed-style enum rather than a bare bool because the *reason* decides
/// what the UI does: a blob that has expired sends the user to the renewal
/// screen, a blob signed for another handset sends them to login, and a
/// missing blob means only "no offline proof", never "not entitled".
enum EntitlementVerdict {
  /// Signature, device binding and both time bounds all hold.
  valid,

  /// No blob stored. **Not a denial** — see `DEVIATIONS.md` D-2: the backend
  /// legitimately omits it whenever `ENTITLEMENT_PRIVATE_KEY` is unset, and
  /// treating that as "not entitled" would lock out a paying user.
  absent,

  /// Structurally not a compact JWS, or claims of the wrong type.
  malformed,

  /// The signature does not verify against the shipped public key, or the
  /// header asked for an algorithm other than EdDSA.
  badSignature,

  /// Signed for a different installation UUID. A blob copied to another
  /// handset lands here, which is what stops it being a transferable licence.
  wrongDevice,

  /// `now >= exp`.
  expired,

  /// `now < iat` — the blob claims to have been issued in the future, which
  /// is what a rolled-back device clock looks like from in here.
  notYetValid,
}

/// The claims the backend actually signs.
///
/// ⚠ These are JWS claim names, not the field names in `INTERFACES.md` §5.
/// The two disagree and the disagreement is recorded in `DEVIATIONS.md` D-1
/// rather than papered over: the backend emits a compact JWS with
/// `sub`/`did`/`iat`/`exp`, and **no `graceDays`**.
@immutable
class EntitlementClaims {
  const EntitlementClaims({
    required this.userId,
    required this.deviceId,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String userId;
  final String deviceId;
  final DateTime issuedAt;
  final DateTime expiresAt;
}

@immutable
class EntitlementResult {
  const EntitlementResult(this.verdict, [this.claims]);

  final EntitlementVerdict verdict;
  final EntitlementClaims? claims;

  bool get isValid => verdict == EntitlementVerdict.valid;
}

/// Verifies the offline entitlement blob against the shipped **public** key.
///
/// The private half never leaves the server, so a tampered blob cannot be
/// re-signed on the handset. That is the whole security story here: everything
/// else in this file is parsing.
///
/// ══ THE TIME ARGUMENT IS NOT A CONVENIENCE ══
///
/// [verify] takes `now` rather than calling `DateTime.now()` because the caller
/// must pass the **monotonic high-water mark** (`MonotonicClock`). Reading the
/// raw wall clock here would make every time check defeatable by changing the
/// date in Settings. It is a parameter so that it is impossible to forget.
class EntitlementVerifier {
  EntitlementVerifier(this._publicKey);

  /// Builds a verifier from an SPKI PEM public key — the format produced by
  /// `openssl pkey -in private.pem -pubout`, which is what the backend's own
  /// key-generation instructions emit.
  factory EntitlementVerifier.fromPem(String pem) =>
      EntitlementVerifier(_publicKeyFromSpkiPem(pem));

  final SimplePublicKey _publicKey;

  static final Ed25519 _algorithm = Ed25519();

  /// Verifies [blob] for [deviceId] at [now].
  ///
  /// [blob] may be null: `INTERFACES.md` §4 shows `entitlement` as always
  /// present but the backend types it `string | null`, and a session with no
  /// blob is a legitimate state (`DEVIATIONS.md` D-2).
  Future<EntitlementResult> verify({
    required String? blob,
    required String deviceId,
    required DateTime now,
  }) async {
    if (blob == null || blob.isEmpty) {
      return const EntitlementResult(EntitlementVerdict.absent);
    }

    final List<String> parts = blob.split('.');
    if (parts.length != 3) {
      return const EntitlementResult(EntitlementVerdict.malformed);
    }

    final Map<String, dynamic>? header = _decodeJsonSegment(parts[0]);
    final Map<String, dynamic>? payload = _decodeJsonSegment(parts[1]);
    if (header == null || payload == null) {
      return const EntitlementResult(EntitlementVerdict.malformed);
    }

    // Pin the algorithm. PROVEN load-bearing by removing it: exactly one test
    // goes red, `alg:none`. It is checked BEFORE the signature so a forged
    // header never reaches the verifier.
    if (header['alg'] != 'EdDSA') {
      return const EntitlementResult(EntitlementVerdict.badSignature);
    }

    final Uint8List? signature = _b64urlBytes(parts[2]);
    if (signature == null) {
      return const EntitlementResult(EntitlementVerdict.malformed);
    }
    // ⚠ THE LENGTH CHECK IS NOT PEDANTRY, and it was found by falsification
    // rather than by design. `Ed25519.verify` THROWS
    //   Bad state: Ed25519 signature must be 64 bytes (got 0 bytes)
    // on a wrong-length signature instead of returning false, and this
    // verifier runs at app start inside the gate — so an escaped exception
    // here is not a failed login, it is a handset that will not launch.
    //
    // Measured, because a blanket `catch` around the verify call passes the
    // same tests and it was worth knowing which one actually carries the
    // weight:
    //   length check ON,  catch off  → 15/15 pass
    //   length check off, catch ON   → 15/15 pass
    //   both off                     → the TRUNCATED test throws
    // They are redundant, so only this one is kept: it names the reason, and
    // a bare `catch (_)` around a crypto call would swallow failures that
    // ought to be loud (`CLAUDE.md` §2).
    if (signature.length != _ed25519SignatureBytes) {
      return const EntitlementResult(EntitlementVerdict.badSignature);
    }

    // A JWS signs the ASCII of `header.payload`, exactly as they appear on the
    // wire. Nothing is re-encoded, which is the reason the JWS shape is easier
    // to get right than §5's `canonical_json` — there are no bytes to
    // reproduce, only bytes to read.
    final Uint8List signedBytes =
        Uint8List.fromList(ascii.encode('${parts[0]}.${parts[1]}'));

    final bool signatureOk = await _algorithm.verify(
      signedBytes,
      signature: Signature(signature, publicKey: _publicKey),
    );
    if (!signatureOk) {
      return const EntitlementResult(EntitlementVerdict.badSignature);
    }

    final Object? sub = payload['sub'];
    final Object? did = payload['did'];
    final Object? iat = payload['iat'];
    final Object? exp = payload['exp'];
    if (sub is! String || did is! String || iat is! num || exp is! num) {
      return const EntitlementResult(EntitlementVerdict.malformed);
    }

    final EntitlementClaims claims = EntitlementClaims(
      userId: sub,
      deviceId: did,
      issuedAt: _fromEpochSeconds(iat),
      expiresAt: _fromEpochSeconds(exp),
    );

    // Device binding is checked before expiry so a stolen blob reports the
    // honest reason rather than whichever check happens to fail first.
    if (did != deviceId) {
      return EntitlementResult(EntitlementVerdict.wrongDevice, claims);
    }
    if (!now.isBefore(claims.expiresAt)) {
      return EntitlementResult(EntitlementVerdict.expired, claims);
    }
    if (now.isBefore(claims.issuedAt)) {
      // The clock is behind the moment the server signed this. Honest causes
      // exist (a few seconds of skew), but so does the attack, and the
      // monotonic mark is what keeps an honest device from landing here twice.
      return EntitlementResult(EntitlementVerdict.notYetValid, claims);
    }

    // ── `graceDays` GOES HERE, and is deliberately absent ──────────────────
    // `INTERFACES.md` §5 requires a second, tighter ceiling:
    //     now < issuedAt + graceDays          (graceDays = 14)
    // The backend does not emit the claim, so the check cannot be written
    // against anything real yet — see `DEVIATIONS.md` D-1, which is open and
    // waiting on Saam. When the claim lands it is ONE comparison, on this
    // line, against the same `now` every other bound above already uses.

    return EntitlementResult(EntitlementVerdict.valid, claims);
  }

  static DateTime _fromEpochSeconds(num seconds) =>
      DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round(), isUtc: true);

  static Map<String, dynamic>? _decodeJsonSegment(String segment) {
    final Uint8List? bytes = _b64urlBytes(segment);
    if (bytes == null) return null;
    try {
      final Object? decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// base64url without padding, which is what JWS uses. Dart's decoder demands
  /// padding, so it is restored here rather than hoping the segment length
  /// happens to be a multiple of four.
  static Uint8List? _b64urlBytes(String segment) {
    try {
      final int remainder = segment.length % 4;
      final String padded =
          remainder == 0 ? segment : segment + ('=' * (4 - remainder));
      return base64Url.decode(padded);
    } catch (_) {
      return null;
    }
  }

  /// The 12-byte SPKI prefix an Ed25519 public key always carries:
  /// SEQUENCE { SEQUENCE { OID 1.3.101.112 }, BIT STRING }.
  /// Ed25519 signatures are always exactly this long.
  static const int _ed25519SignatureBytes = 64;

  static const List<int> _ed25519SpkiPrefix = <int>[
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
  ];

  static SimplePublicKey _publicKeyFromSpkiPem(String pem) {
    final String body = pem
        .replaceAll(RegExp(r'-----(BEGIN|END)[^-]*-----'), '')
        .replaceAll(RegExp(r'\s'), '');
    if (body.isEmpty) {
      throw ArgumentError('entitlement public key is empty');
    }
    final Uint8List der = base64.decode(body);
    if (der.length != _ed25519SpkiPrefix.length + 32) {
      throw ArgumentError(
        'entitlement public key is not an Ed25519 SPKI key '
        '(${der.length} bytes, expected ${_ed25519SpkiPrefix.length + 32})',
      );
    }
    for (int i = 0; i < _ed25519SpkiPrefix.length; i++) {
      if (der[i] != _ed25519SpkiPrefix[i]) {
        // Refusing here rather than silently taking the last 32 bytes: an RSA
        // or P-256 key would otherwise be accepted as garbage and every blob
        // would fail verification with no clue why.
        throw ArgumentError('entitlement public key is not Ed25519');
      }
    }
    return SimplePublicKey(
      der.sublist(_ed25519SpkiPrefix.length),
      type: KeyPairType.ed25519,
    );
  }
}
