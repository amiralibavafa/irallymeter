import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../domain/api_error.dart';
import '../domain/entitlement.dart';
import '../domain/monotonic_clock.dart';
import '../domain/session.dart';
import 'api_client.dart';
import 'device_identity.dart';
import 'secure_store.dart';

/// What the gate decides at launch, from **local state only**.
enum GateDecision {
  /// Render the rally computer. Either a signed entitlement verified, or a
  /// stored subscription that has not lapsed.
  admitted,

  /// Show the account flow, starting at phone entry.
  needsLogin,

  /// No API base URL was compiled in. A build problem, not a user problem, and
  /// shown as one rather than as an unexplained login screen that can never
  /// succeed.
  misconfigured,
}

@immutable
class GateState {
  const GateState(this.decision, {this.session, this.reason});

  final GateDecision decision;
  final Session? session;

  /// Why entitlement was refused, when it was. Diagnostic only — never shown
  /// as a raw enum to a user.
  final EntitlementVerdict? reason;

  bool get isAdmitted => decision == GateDecision.admitted;
}

/// Owns the session: where it lives, how it is restored, and the ONE decision
/// the gate makes at launch.
///
/// ══ THE INVARIANT THIS CLASS EXISTS TO PROTECT ══
///
/// `SPEC.md` §4: *"The rally computer must run with zero connectivity and must
/// gain NO new API dependency. The speedometer never awaits a network call."*
///
/// ⇒ [restore] performs **no I/O over the network**, and it is the only thing
///   the gate awaits before rendering. A token refresh, a membership check or
///   a "verify entitlement with the server" call on the launch path would each
///   read as reasonable in isolation and each would break this. Refresh happens
///   lazily, on a 401 from a route the user actually invoked, never at boot.
///   `test/account_gate_test.dart` builds the gate with an API client that
///   THROWS on any call and asserts the app still renders.
class AccountRepository {
  AccountRepository({
    required SecureStore store,
    required AccountApi api,
    required DeviceIdentity identity,
    required MonotonicClock clock,
    EntitlementVerifier? verifier,
  })  : _store = store,
        _api = api,
        _identity = identity,
        _clock = clock,
        _verifier = verifier;

  final SecureStore _store;
  final AccountApi _api;
  final DeviceIdentity _identity;
  final MonotonicClock _clock;

  /// Null when no public key was compiled in. A build with no key cannot
  /// verify a blob, so it falls back to the stored expiry rather than locking
  /// every user out — the same reasoning as `DEVIATIONS.md` D-2.
  final EntitlementVerifier? _verifier;

  // ── the launch path ───────────────────────────────────────────────────────

  /// Decides whether to render the rally computer, from disk alone.
  Future<GateState> restore() async {
    if (!_api.isConfigured) {
      return const GateState(GateDecision.misconfigured);
    }

    final Session? session = await readSession();
    if (session == null) return const GateState(GateDecision.needsLogin);

    // The monotonic mark, never `DateTime.now()`. Everything below compares
    // against this one value, so a rolled-back clock cannot pass one check and
    // fail another.
    final DateTime now = await _clock.now();
    final String deviceId = await _identity.installationId();

    final String? blob = session.entitlement;
    if (_verifier != null && blob != null && blob.isNotEmpty) {
      final EntitlementResult result = await _verifier.verify(
        blob: blob,
        deviceId: deviceId,
        now: now,
      );
      if (result.isValid) {
        return GateState(GateDecision.admitted, session: session);
      }
      // A blob that EXISTS and does not verify is a refusal, not a fallback.
      // Falling back to the unsigned expiry here would make the signature
      // decorative: an attacker would simply corrupt the blob. This is also
      // where a blob bound to ANOTHER handset lands, which is what stops it
      // being a transferable licence.
      return GateState(GateDecision.needsLogin, reason: result.verdict);
    }

    // No blob, or no key to check it with. `DEVIATIONS.md` D-2: a legitimate
    // state, not a denial, so the stored subscription expiry decides. It is
    // unsigned, but it lives in the platform keystore rather than in Hive, so
    // editing it is not the trivial file edit Hive would be.
    final DateTime? expiresAt = session.subscriptionExpiresAt;
    final bool live = expiresAt != null && now.isBefore(expiresAt);
    return live
        ? GateState(GateDecision.admitted,
            session: session, reason: EntitlementVerdict.absent)
        : const GateState(GateDecision.needsLogin,
            reason: EntitlementVerdict.absent);
  }

  // ── persistence ───────────────────────────────────────────────────────────

  /// Reads the session back. The refresh token lives under its own key and is
  /// re-attached here; see [Session.toJsonWithoutRefreshToken] for why.
  Future<Session?> readSession() async {
    final String? raw = await _store.read(SecureKeys.session);
    final String? refresh = await _store.read(SecureKeys.refreshToken);
    if (raw == null || refresh == null) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return Session.restore(decoded, refresh);
    } catch (_) {
      // A corrupt session is cleared rather than retried forever. The user
      // logs in again, which is recoverable; a launch-time crash is not.
      return null;
    }
  }

  /// Persists a session.
  ///
  /// ⚠ **The refresh token is written FIRST, and that order is not
  /// cosmetic.** Rotation is strict (`INTERFACES.md` §2): the token we just
  /// used is already dead server-side. If the process died between writing the
  /// session and writing the token, the next launch would present the OLD
  /// token, the server would read that as REUSE, and it would revoke the
  /// entire family — logging the user out of a subscription they paid for.
  /// Writing the token first makes the worst case a stale access token, which
  /// refresh fixes by itself.
  Future<void> saveSession(Session session) async {
    await _store.write(SecureKeys.refreshToken, session.refreshToken);
    await _store.write(
      SecureKeys.session,
      jsonEncode(session.toJsonWithoutRefreshToken()),
    );

    final String? blob = session.entitlement;
    if (blob == null || blob.isEmpty) return;
    await _store.write(SecureKeys.entitlement, blob);

    // ⚠ THIS IS THE ONLY SERVER TIME THE CLIENT EVER SEES.
    //
    // `INTERFACES.md` §3 returns `serverTime` from `/subscription/status` so
    // the client never has to trust its own clock. That route does not exist —
    // `/membership` returns `{active, expiresAt}` and nothing else — so the
    // blob's `iat`, which IS server truth at signing time, is used instead.
    //
    // The cost, stated rather than implied: `iat` only arrives when a NEW blob
    // does, and a build with no entitlement key gets no server time at all and
    // runs on the wall-clock ratchet alone. It is not a full replacement for
    // `serverTime`. See `DEVIATIONS.md` D-3.
    //
    // Only a VERIFIED blob is allowed to move the mark. An unverified `iat`
    // would let a forged blob push the mark past a real expiry, which locks the
    // user out — the wrong direction to fail in.
    final EntitlementVerifier? verifier = _verifier;
    if (verifier == null) return;
    final EntitlementResult result = await verifier.verify(
      blob: blob,
      deviceId: await _identity.installationId(),
      now: await _clock.now(),
    );
    if (result.isValid && result.claims != null) {
      await _clock.observe(result.claims!.issuedAt);
    }
  }

  /// Wipes the session. **Does not touch the installation UUID** — logout ends
  /// a session, it does not make this a different phone (`INTERFACES.md` §0
  /// R4).
  Future<void> clear() async {
    await _store.delete(SecureKeys.session);
    await _store.delete(SecureKeys.refreshToken);
    await _store.delete(SecureKeys.entitlement);
  }

  // ── network, none of which is on the launch path ──────────────────────────

  Future<SendCodeResult> sendCode(String phone) => _api.sendCode(phone);

  Future<VerifyCodeResult> verifyCode({
    required String otpToken,
    required String code,
    required String phone,
  }) async {
    final VerifyCodeResult result = await _api.verifyCode(
      otpToken: otpToken,
      code: code,
      device: await _identity.describe(),
      phone: phone,
    );
    if (result.session != null) await saveSession(result.session!);
    return result;
  }

  /// Force Login. Requires a fresh code, not just the token — see the note in
  /// [AccountApi.forceLogin].
  Future<VerifyCodeResult> forceLogin({
    required String otpToken,
    required String code,
    required String phone,
  }) async {
    final VerifyCodeResult result = await _api.forceLogin(
      otpToken: otpToken,
      code: code,
      device: await _identity.describe(),
      phone: phone,
    );
    if (result.session != null) await saveSession(result.session!);
    return result;
  }

  /// Rotates the refresh token. Called lazily on a 401, never at boot.
  ///
  /// A revoked or reused token clears local state, because `INTERFACES.md` §1
  /// says `SESSION_REVOKED` and `DEVICE_REVOKED` mean a full logout — keeping
  /// a dead session would put the user in a loop.
  Future<Session?> refreshSession() async {
    final Session? current = await readSession();
    if (current == null) return null;
    try {
      final Session refreshed = await _api.refresh(current.refreshToken);
      await saveSession(refreshed);
      return refreshed;
    } on ApiException catch (e) {
      switch (e.code) {
        case ApiErrorCode.sessionRevoked:
        case ApiErrorCode.deviceRevoked:
        case ApiErrorCode.subscriptionExpired:
          await clear();
          rethrow;
        default:
          // Offline or a transient server fault. The session is NOT cleared:
          // a user in a valley must not be logged out by a failed refresh.
          rethrow;
      }
    }
  }

  Future<DeviceDescriptor> describeDevice() => _identity.describe();

  /// Public pricing for the membership screen.
  Future<List<Plan>> plans() => _api.plans();

  /// Starts a payment. [bearer] is a payment token for a user who is not signed in
  /// yet, or an access token for a signed-in user renewing early.
  Future<PaymentStart> startPayment({
    required String planCode,
    required String bearer,
  }) =>
      _api.startPayment(planCode: planCode, bearer: bearer);

  /// Turns a payment token into a session, once the server agrees the subscription is
  /// live. Saves the session if one comes back.
  Future<VerifyCodeResult> claimSession({
    required String paymentToken,
    required String phone,
  }) async {
    final VerifyCodeResult result = await _api.claimSession(
      paymentToken: paymentToken,
      device: await _identity.describe(),
      phone: phone,
    );
    if (result.session != null) await saveSession(result.session!);
    return result;
  }

  Future<void> logout() async {
    final Session? current = await readSession();
    if (current != null) {
      try {
        // Server-side FIRST (`INTERFACES.md` §3): local state is cleared only
        // after the server has revoked the family, or a "logout" that failed
        // silently would leave a live session on the server.
        //
        // Authenticated with the ACCESS token — the backend's `/auth/logout`
        // calls `requireAuth` and revokes by the `did` claim, rather than
        // taking a refresh token in the body as the document says.
        await _api.logout(current.accessToken);
      } on ApiException {
        // ...but a user who taps Log out with no signal must still end up
        // logged out locally. The server-side row expires with the
        // subscription anyway.
      }
    }
    await clear();
  }
}
