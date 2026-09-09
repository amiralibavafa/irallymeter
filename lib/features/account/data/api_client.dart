import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/api_error.dart';
import '../domain/session.dart';
import 'device_identity.dart';

/// The backend's base URL.
///
/// ══ TODO — NOT YET KNOWN. Supply at build time. ══
///
///   flutter build apk --dart-define=IRALLYMETER_API_BASE_URL=https://api.example.ir
///
/// This is the client-side equivalent of the backend's `.env`: a name and a
/// TODO, never a value in the repo (`SPEC.md` §4). It is deliberately EMPTY by
/// default rather than pointing at a placeholder host, because a build that
/// silently talked to the wrong server would be worse than one that refuses to
/// talk at all — see [AccountApi.isConfigured], which the gate checks so an
/// unconfigured build fails visibly instead of looking like a network outage.
const String kApiBaseUrl =
    String.fromEnvironment('IRALLYMETER_API_BASE_URL', defaultValue: '');

/// Every call the account layer makes. Nothing else in the app performs I/O
/// against this backend.
///
/// ⚠ **Nothing here is on the rally computer's path.** GPS, distance, the trip
/// meters and the compass never call into this class, which is what keeps
/// `SPEC.md` §4's *"the speedometer never awaits a network call"* true.
class AccountApi {
  AccountApi({
    String baseUrl = kApiBaseUrl,
    http.Client? client,
    Duration timeout = const Duration(seconds: 20),
  })  : _baseUrl = baseUrl,
        _client = client ?? http.Client(),
        _timeout = timeout;

  final String _baseUrl;
  final http.Client _client;

  /// Every request is bounded. An unbounded call would hang the login screen
  /// indefinitely on a captive portal, which looks identical to a hung app.
  final Duration _timeout;

  /// False when no base URL was compiled in. The gate reports this as a build
  /// problem rather than showing the user a login screen that cannot work.
  bool get isConfigured => _baseUrl.isNotEmpty;

  // ── auth ──────────────────────────────────────────────────────────────────

  /// `POST /auth/send-code`.
  ///
  /// The phone is sent as the user typed it; **the server normalises to E.164**
  /// (`INTERFACES.md` §3). Normalising here as well would create a second
  /// implementation of a rule that has to agree exactly, and the server's is
  /// the one that owns the UNIQUE index.
  Future<SendCodeResult> sendCode(String phone) async {
    final Map<String, dynamic> body =
        await _post('/auth/send-code', <String, dynamic>{'phone': phone});
    final Object? token = body['otpToken'];
    if (token is! String) throw _malformed('send-code');
    return SendCodeResult(
      otpToken: token,
      expiresAt: _utc(body['expiresAt']),
      attemptsAllowed:
          body['attemptsAllowed'] is num ? (body['attemptsAllowed'] as num).toInt() : null,
    );
  }

  /// `POST /auth/verify-code`.
  ///
  /// Four outcomes, three of them successes discriminated by `next`; the
  /// fourth, `DEVICE_CONFLICT`, arrives as a 409 and is thrown as an
  /// [ApiException] carrying the other device.
  Future<VerifyCodeResult> verifyCode({
    required String otpToken,
    required String code,
    required DeviceDescriptor device,
    String? phone,
  }) async {
    final Map<String, dynamic> body = await _post(
      '/auth/verify-code',
      <String, dynamic>{
        // ⚠ `code`, NOT `pin`. `INTERFACES.md` §3 says `pin`; the backend's
        // zod schema says `code`, and a `pin` field is rejected as a
        // VALIDATION_ERROR. See DEVIATIONS.md D-3.
        'otpToken': otpToken,
        'code': code,
        'device': device.toJson(),
      },
    );
    return _readVerify(body, phone: phone);
  }

  /// `POST /auth/force-login`. Requires a FRESH, unused `otpToken`
  /// (`INTERFACES.md` §3) — one already spent on `/auth/verify-code` is
  /// refused, so a Force Login can never be replayed.
  Future<VerifyCodeResult> forceLogin({
    required String otpToken,
    required String code,
    required DeviceDescriptor device,
    String? phone,
  }) async {
    final Map<String, dynamic> body = await _post(
      '/auth/force-login',
      <String, dynamic>{
        // ⚠ The CODE is required here too, and that is the backend being
        // right where the document is wrong: `INTERFACES.md` §3 shows
        // `{otpToken, device}` with no code, which taken literally would let
        // anyone who can call send-code evict the real owner's device.
        'otpToken': otpToken,
        'code': code,
        'device': device.toJson(),
      },
    );
    // Same envelope as verify-code, including PAYMENT_REQUIRED for a user
    // whose subscription has lapsed. There is no `revokedDevice` field.
    return _readVerify(body, phone: phone);
  }

  /// `POST /auth/refresh`.
  ///
  /// ⚠ Rotation is strict: the token passed in is dead afterwards, and the new
  /// one MUST be persisted before anything else can fail, or the next launch
  /// presents an already-rotated token and the server revokes the whole family
  /// as reuse (`INTERFACES.md` §2). The persistence ordering is enforced by
  /// the caller, `AccountRepository`.
  Future<Session> refresh(String refreshToken, {String? phone}) async {
    final Map<String, dynamic> body = await _post(
        '/auth/refresh', <String, dynamic>{'refreshToken': refreshToken});
    final Session? session = Session.fromJson(body['session'], phone: phone);
    if (session == null) throw _malformed('refresh');
    return session;
  }

  /// `POST /auth/logout`. Answers 204.
  ///
  /// ⚠ Authenticated with the ACCESS token, not the refresh token in a body.
  /// `INTERFACES.md` §3 says the opposite; the backend calls `requireAuth` and
  /// revokes by the `did` claim (`DEVIATIONS.md` D-3).
  Future<void> logout(String accessToken) async {
    await _post(
      '/auth/logout',
      const <String, dynamic>{},
      bearer: accessToken,
      expectBody: false,
    );
  }

  // ── subscription and payment ──────────────────────────────────────────────

  /// `GET /membership`.
  ///
  /// ⚠ Not `/subscription/status`, and it returns only `{active, expiresAt}` —
  /// no `serverTime`, no `plan`, no `entitlement`. The monotonic clock is
  /// therefore seeded from the entitlement blob's `iat` instead, and the
  /// membership screen has no price to render (`DEVIATIONS.md` D-3).
  Future<Membership> membership(String accessToken) async {
    final Map<String, dynamic> body =
        await _get('/membership', bearer: accessToken);
    return Membership.fromJson(body);
  }

  /// `POST /payment/start`.
  ///
  /// ⚠⚠ **Requires a Bearer ACCESS token, and the users who need to pay do not
  /// have one.** `verify-code` answers `PAYMENT_REQUIRED` with a bare `userId`,
  /// nothing mints a token from it, and this route opens with `requireAuth`.
  /// So every call from the state that needs payment is a 401. The method is
  /// written and correct for the day that gap closes; it is not reachable from
  /// the UI, and the membership screen says so rather than pretending. Traced
  /// end to end in `DEVIATIONS.md` D-3, category 2.
  Future<PaymentStart> startPayment({
    required String planCode,
    required String accessToken,
  }) async {
    final Map<String, dynamic> body = await _post(
      '/payment/start',
      <String, dynamic>{'planCode': planCode},
      bearer: accessToken,
    );
    final Object? url = body['paymentUrl'];
    final Object? authority = body['authority'];
    if (url is! String || authority is! String) {
      throw _malformed('payment/start');
    }
    return PaymentStart(paymentUrl: url, authority: authority);
  }

  void close() => _client.close();

  // ── plumbing ──────────────────────────────────────────────────────────────

  VerifyCodeResult _readVerify(Map<String, dynamic> body, {String? phone}) {
    final VerifyNext? next = VerifyNext.parse(body['next']);
    if (next == null) throw _malformed('verify-code');
    if (next == VerifyNext.session) {
      final Session? session = Session.fromJson(body['session'], phone: phone);
      if (session == null) throw _malformed('verify-code session');
      return VerifyCodeResult(next: next, session: session);
    }
    return VerifyCodeResult(
      next: next,
      userId: body['userId'] is String ? body['userId'] as String : null,
    );
  }

  Future<Map<String, dynamic>> _get(String path, {String? bearer}) =>
      _send(() => _client.get(_uri(path), headers: _headers(bearer: bearer)));

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    String? bearer,
    bool expectBody = true,
  }) =>
      _send(
        () => _client.post(
          _uri(path),
          headers: _headers(bearer: bearer, json: true),
          body: jsonEncode(body),
        ),
        expectBody: expectBody,
      );

  Uri _uri(String path) {
    if (!isConfigured) {
      throw const ApiException(
        ApiErrorCode.offline,
        message: 'No API base URL was compiled into this build.',
      );
    }
    // A trailing slash on the base would produce `//auth/send-code`, which some
    // gateways route differently. Trimmed rather than trusted.
    return Uri.parse('${_baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');
  }

  Map<String, String> _headers({String? bearer, bool json = false}) =>
      <String, String>{
        'accept': 'application/json',
        if (json) 'content-type': 'application/json',
        if (bearer != null) 'authorization': 'Bearer $bearer',
      };

  Future<Map<String, dynamic>> _send(
    Future<http.Response> Function() request, {
    bool expectBody = true,
  }) async {
    http.Response response;
    try {
      response = await request().timeout(_timeout);
    } on ApiException {
      rethrow;
    } catch (_) {
      // ⚠ The exception is swallowed DELIBERATELY and this is the one place it
      // is right to do so: a socket error's message can contain the host, the
      // port and sometimes the full URL, and this object is what the UI
      // renders. `SPEC.md` §4 forbids leaking connection details, and the user
      // can do nothing with them anyway.
      throw const ApiException(ApiErrorCode.offline);
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (!expectBody || response.body.isEmpty) return const <String, dynamic>{};
      final Object? decoded = _decode(response.body);
      if (decoded is! Map<String, dynamic>) throw _malformed('response body');
      return decoded;
    }
    throw _errorFrom(response);
  }

  ApiException _errorFrom(http.Response response) {
    final Object? decoded = _decode(response.body);
    final Object? envelope =
        decoded is Map<String, dynamic> ? decoded['error'] : null;
    if (envelope is! Map) {
      // A non-2xx with no envelope is a proxy, a captive portal or a crash
      // before the error handler. It is not a code we may invent.
      return ApiException(
        ApiErrorCode.unknown,
        statusCode: response.statusCode,
      );
    }
    final Object? retry = envelope['retryAfterSeconds'];
    return ApiException(
      ApiErrorCode.parse(envelope['code'] as String?),
      message: envelope['message'] is String ? envelope['message'] as String : null,
      retryAfterSeconds: retry is num ? retry.toInt() : null,
      conflictingDevice: ConflictingDevice.fromJson(envelope['activeDevice']),
      statusCode: response.statusCode,
    );
  }

  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// A well-formed HTTP response whose SHAPE is wrong. Reported as `INTERNAL`
  /// rather than as a parse crash: it is a bug on one side of the contract,
  /// and `INTERFACES.md` §1 says the client shows a generic message for that.
  static ApiException _malformed(String what) => ApiException(
        ApiErrorCode.internal,
        message: 'Unexpected response shape from $what',
      );

  static DateTime? _utc(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}
