import 'package:flutter/foundation.dart';

/// Every error the backend can return, as a closed enum.
///
/// `INTERFACES.md` §1: *"`code` is a closed enum. The client switches on `code`
/// and **never** parses `message`."* That rule is why this type exists rather
/// than passing strings around — a `message` is written for a human, may be
/// translated, and is the one field in the envelope that is allowed to change
/// without a contract change.
enum ApiErrorCode {
  otpInvalid('OTP_INVALID'),
  otpExpired('OTP_EXPIRED'),
  otpAttemptsExhausted('OTP_ATTEMPTS_EXHAUSTED'),
  otpSendFailed('OTP_SEND_FAILED'),
  rateLimited('RATE_LIMITED'),
  deviceConflict('DEVICE_CONFLICT'),
  subscriptionExpired('SUBSCRIPTION_EXPIRED'),
  noAccount('NO_ACCOUNT'),
  unauthorized('UNAUTHORIZED'),
  sessionRevoked('SESSION_REVOKED'),
  deviceRevoked('DEVICE_REVOKED'),
  paymentFailed('PAYMENT_FAILED'),
  paymentNotVerified('PAYMENT_NOT_VERIFIED'),
  validationError('VALIDATION_ERROR'),
  internal('INTERNAL'),

  /// Force Login was used on this account within the last 24 hours.
  forceLoginCooldown('FORCE_LOGIN_COOLDOWN'),

  /// The wire carried a `code` this build does not know.
  ///
  /// Not in `INTERFACES.md` and deliberately so: the enum is closed by the
  /// contract, but a client in someone's pocket cannot be recompiled when the
  /// server ships a new one. Treating an unknown code as a crash would turn a
  /// server-side addition into a field outage, so it degrades to a generic
  /// message instead.
  unknown('UNKNOWN'),

  /// The request never got an answer. Not a server code at all — a socket
  /// failure, a DNS failure, a timeout, an airplane-mode tap.
  ///
  /// Kept in the same enum because every screen has to branch on it, and a
  /// separate exception type would let a caller forget.
  offline('OFFLINE');

  const ApiErrorCode(this.wire);

  /// The exact string the backend sends.
  final String wire;

  static ApiErrorCode parse(String? code) {
    for (final ApiErrorCode value in ApiErrorCode.values) {
      if (value.wire == code) return value;
    }
    return ApiErrorCode.unknown;
  }
}

/// The other device in a `DEVICE_CONFLICT`.
///
/// `INTERFACES.md` §3: it carries `deviceName` and `lastSeen` *"and nothing
/// else — enough to let a person recognise their own other phone, not enough
/// to profile it."*
@immutable
class ConflictingDevice {
  const ConflictingDevice({this.deviceName, this.lastSeen});

  /// ⚠ NULLABLE, because the backend really sends null here. `deviceName` is
  /// optional on registration, so a device that was registered without one comes
  /// back as `{"deviceName": null, "lastSeen": "..."}` — measured against the live
  /// service, not assumed.
  final String? deviceName;
  final DateTime? lastSeen;

  /// ⚠⚠ A NULL NAME NO LONGER DISCARDS THE WHOLE OBJECT. This used to bail with
  /// `if (name is! String) return null`, which threw away a perfectly good
  /// `lastSeen` alongside it and left the conflict screen unable to say when the
  /// other phone was last used. The existing test only ever passed a real name, so
  /// the branch that actually ships was never exercised.
  ///
  /// Junk is still refused: a non-Map is null, and a name of the wrong TYPE is
  /// dropped rather than stringified, so `deviceName: 42` cannot reach the UI.
  static ConflictingDevice? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? name = json['deviceName'];
    final Object? seen = json['lastSeen'];
    final DateTime? lastSeen =
        seen is String ? DateTime.tryParse(seen)?.toUtc() : null;
    // Nothing usable at all is still nothing.
    if (name is! String && lastSeen == null) return null;
    return ConflictingDevice(
      deviceName: name is String ? name : null,
      lastSeen: lastSeen,
    );
  }
}

/// A non-2xx response, or a transport failure.
class ApiException implements Exception {
  const ApiException(
    this.code, {
    this.message,
    this.retryAfterSeconds,
    this.conflictingDevice,
    this.statusCode,
  });

  final ApiErrorCode code;

  /// The server's own words. Displayed only where the contract says a human
  /// message is appropriate; **never** switched on.
  final String? message;

  /// From `RATE_LIMITED`. `INTERFACES.md` §1 says the client shows it.
  final int? retryAfterSeconds;

  /// From `DEVICE_CONFLICT`.
  final ConflictingDevice? conflictingDevice;

  final int? statusCode;

  @override
  String toString() => 'ApiException(${code.wire}, status=$statusCode)';
}
