import 'package:flutter/foundation.dart';

/// ══ THESE SHAPES COME FROM THE BACKEND, NOT FROM `INTERFACES.md` ══
///
/// The two disagree on almost every field, and `DEVIATIONS.md` D-3 records why
/// the backend wins: `INTERFACES.md` still reads *"STATUS: PROPOSED. Not signed
/// off. No implementation may start against it yet."* It never became binding,
/// and the backend is the only implemented artifact.
///
/// Concretely, what the server actually sends as a session is FLAT:
///
/// ```json
/// { "accessToken": "…", "accessExpiresAt": "…",
///   "refreshToken": "…", "refreshExpiresAt": "…",
///   "entitlement": "<compact JWS>|null",
///   "subscriptionExpiresAt": "…" }
/// ```
///
/// There is no `user`, no `device`, no `plan`, no `status` and no `serverTime`.

/// All timestamps on the wire are RFC 3339 UTC from the SERVER clock. They are
/// parsed to UTC and kept that way; a local `DateTime` would compare wrong
/// against an expiry by the timezone offset, which is 3.5 or 4.5 hours in Iran.
DateTime? _utc(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

/// The session, exactly as `serialiseSession` in `app.ts` builds it.
@immutable
class Session {
  const Session({
    required this.accessToken,
    required this.refreshToken,
    required this.subscriptionExpiresAt,
    this.accessExpiresAt,
    this.refreshExpiresAt,
    this.entitlement,
    this.phone,
  });

  final String accessToken;

  /// ⚠ Secure storage only, and only ever sent in the body of `/auth/refresh`.
  /// Deliberately excluded from [toJsonWithoutRefreshToken].
  final String refreshToken;

  /// The subscription's expiry on the SERVER clock. This is the whole of what
  /// the backend tells us about membership inside a session.
  final DateTime? subscriptionExpiresAt;

  final DateTime? accessExpiresAt;

  /// Equals [subscriptionExpiresAt] server-side: the session lives exactly as
  /// long as the subscription, which is R1 in `INTERFACES.md` §0.
  final DateTime? refreshExpiresAt;

  /// The compact JWS entitlement blob, or null.
  ///
  /// ⚠ Null is a legitimate state, not a denial — the backend omits it whenever
  /// it started without `ENTITLEMENT_PRIVATE_KEY` (`DEVIATIONS.md` D-2).
  final String? entitlement;

  /// ⚠ **Client-known, never server-returned.** The backend sends no `user`
  /// object, so the only phone number the app can show is the one the user
  /// typed. Kept here so the account screens can display it; it is never sent
  /// back as though it were authoritative.
  final String? phone;

  static Session? fromJson(Object? json, {String? phone}) {
    if (json is! Map) return null;
    final Object? access = json['accessToken'];
    final Object? refresh = json['refreshToken'];
    if (access is! String || refresh is! String) return null;
    return Session(
      accessToken: access,
      refreshToken: refresh,
      subscriptionExpiresAt: _utc(json['subscriptionExpiresAt']),
      accessExpiresAt: _utc(json['accessExpiresAt']),
      refreshExpiresAt: _utc(json['refreshExpiresAt']),
      entitlement:
          json['entitlement'] is String ? json['entitlement'] as String : null,
      phone: phone ?? (json['phone'] is String ? json['phone'] as String : null),
    );
  }

  /// The persisted form. **The refresh token is not in it** — it is stored
  /// under its own key, so one value has one home and a bug in session
  /// serialisation cannot spill the token into a diagnostic dump.
  Map<String, dynamic> toJsonWithoutRefreshToken() => <String, dynamic>{
        'accessToken': accessToken,
        if (accessExpiresAt != null)
          'accessExpiresAt': accessExpiresAt!.toIso8601String(),
        if (refreshExpiresAt != null)
          'refreshExpiresAt': refreshExpiresAt!.toIso8601String(),
        if (subscriptionExpiresAt != null)
          'subscriptionExpiresAt': subscriptionExpiresAt!.toIso8601String(),
        if (entitlement != null) 'entitlement': entitlement,
        if (phone != null) 'phone': phone,
      };

  static Session? restore(Map<String, dynamic> stored, String refreshToken) =>
      Session.fromJson(<String, dynamic>{
        ...stored,
        'refreshToken': refreshToken,
      });
}

/// What `verify-code` and `force-login` decided.
///
/// ⚠ There is **no `SIGNUP_REQUIRED`**. The backend deliberately collapses
/// "never subscribed" and "lapsed" into one outcome, so that the response
/// cannot leak whether a number has ever been a customer. `DEVICE_CONFLICT`
/// is not here either: it arrives as a 409 error envelope.
enum VerifyNext {
  /// Straight in. R3: a returning user with a live subscription does not pay
  /// again.
  session('SESSION'),

  /// ⚠ Carries a `userId` and **nothing else** — no session, no token. See
  /// `DEVIATIONS.md` D-3 category 2: there is currently no credential with
  /// which this user can reach `/payment/start`.
  paymentRequired('PAYMENT_REQUIRED');

  const VerifyNext(this.wire);
  final String wire;

  static VerifyNext? parse(Object? value) {
    for (final VerifyNext n in VerifyNext.values) {
      if (n.wire == value) return n;
    }
    return null;
  }
}

@immutable
class VerifyCodeResult {
  const VerifyCodeResult({
    required this.next,
    this.session,
    this.userId,
    this.paymentToken,
    this.paymentTokenExpiresAt,
  });

  final VerifyNext next;
  final Session? session;

  /// Present only on [VerifyNext.paymentRequired].
  final String? userId;

  /// The payment-scoped token — `INTERFACES.md` §3's `signupToken`.
  ///
  /// ⚠ **Not a session.** It authorises exactly two calls, `/payment/start` and
  /// `/auth/claim-session`, and nothing else: it cannot refresh, cannot log out, cannot
  /// read membership, and is bound to no device. Held in MEMORY only, like `otpToken`.
  final String? paymentToken;

  final DateTime? paymentTokenExpiresAt;
}

@immutable
class SendCodeResult {
  const SendCodeResult({
    required this.otpToken,
    this.expiresAt,
    this.attemptsAllowed,
    this.otpRequired = true,
  });

  /// Held in MEMORY only — it never reaches storage.
  final String otpToken;
  final DateTime? expiresAt;
  final int? attemptsAllowed;

  /// False when the server has `SMS_AUTH_ENABLED=false`: no message was sent and the
  /// app must NOT ask for a code.
  ///
  /// ⚠ DEFAULTS TO TRUE, and that direction is the safety property. An older server, a
  /// proxy that drops the field, or a malformed response all leave the app asking for a
  /// code — the strict behaviour — rather than skipping verification.
  final bool otpRequired;
}

/// One purchasable plan, from `GET /plans`.
@immutable
class Plan {
  const Plan({
    required this.code,
    required this.name,
    required this.priceToman,
    required this.days,
  });

  final String code;
  final String name;

  /// ⚠ **TOMAN** — what the user is told, and the only money figure the client ever
  /// sees. The gateway is sent ten times this in Rial; that number is computed on the
  /// server and never reaches here (`INTERFACES.md` §6). Nothing in the client
  /// multiplies or divides it.
  final int priceToman;

  final int days;

  static Plan? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? code = json['code'];
    final Object? price = json['priceToman'];
    final Object? days = json['days'];
    if (code is! String || price is! num || days is! num) return null;
    return Plan(
      code: code,
      name: json['name'] is String ? json['name'] as String : code,
      priceToman: price.toInt(),
      days: days.toInt(),
    );
  }

  /// `400000` -> `۴۰۰٬۰۰۰`-style grouping in Latin digits: `400,000`.
  ///
  /// Grouped by hand rather than with `intl`, which was deliberately removed from this
  /// app in [SA-V2] and is not coming back until localisation lands.
  String get formattedToman {
    final String digits = priceToman.toString();
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }
}

/// `GET /config` — runtime configuration, so a price change needs no new APK.
@immutable
class AppConfig {
  const AppConfig({
    required this.monthlyPrice,
    required this.maintenanceMode,
    required this.paymentEnabled,
    required this.minimumAppVersion,
  });

  /// ⚠ TOMAN. The client never converts it.
  final int monthlyPrice;
  final bool maintenanceMode;
  final bool paymentEnabled;
  final String minimumAppVersion;

  /// Defaults match the backend's, so a failed fetch still yields a usable screen
  /// rather than a blank price.
  static const AppConfig fallback = AppConfig(
    monthlyPrice: 400000,
    maintenanceMode: false,
    paymentEnabled: true,
    minimumAppVersion: '1.0.0',
  );

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        monthlyPrice:
            json['monthlyPrice'] is num ? (json['monthlyPrice'] as num).toInt() : fallback.monthlyPrice,
        maintenanceMode: json['maintenanceMode'] == true,
        // Same asymmetry as the server: payments are ON unless explicitly false.
        paymentEnabled: json['paymentEnabled'] != false,
        minimumAppVersion: json['minimumAppVersion'] is String
            ? json['minimumAppVersion'] as String
            : fallback.minimumAppVersion,
      );

  String get formattedPrice {
    final String digits = monthlyPrice.toString();
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }
}

/// `GET /membership`. The backend returns exactly these two fields.
@immutable
class Membership {
  const Membership({required this.active, this.expiresAt});

  final bool active;
  final DateTime? expiresAt;

  factory Membership.fromJson(Map<String, dynamic> json) => Membership(
        active: json['active'] == true,
        expiresAt: _utc(json['expiresAt']),
      );
}

/// `POST /payment/start`. Returns the gateway URL and the authority.
///
/// ⚠ No amount and no currency unit, so the client has nothing to render as a
/// price and cannot independently confirm the Toman/Rial conversion
/// (`INTERFACES.md` §6). Recorded in `DEVIATIONS.md` D-3. The screen therefore
/// states the price it was told at build time and never computes one.
@immutable
class PaymentStart {
  const PaymentStart({required this.paymentUrl, required this.authority});

  final String paymentUrl;
  final String authority;
}
