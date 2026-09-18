import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/account_repository.dart';
import '../data/deep_link_service.dart';
import '../domain/api_error.dart';
import '../domain/session.dart';
import 'providers/account_providers.dart';

/// Opens the gateway. Injected so a test can drive the payment flow without a browser.
typedef UrlOpener = Future<bool> Function(Uri url);

Future<bool> _defaultOpener(Uri url) => launchUrl(
      url,
      // EXTERNAL, not in-app: ZarinPal hands off to a bank, and the return trip is the
      // `irallymeter://` deep link rather than a webview navigation we could observe.
      mode: LaunchMode.externalApplication,
    );

/// Which screen of the account flow is showing.
enum AccountStep {
  /// Phone entry. Also where every "start again" lands.
  phone,

  /// Code entry.
  code,

  /// This number is signed in on another handset. Offers Force Login.
  conflict,

  /// Payment is required — a new number, or a lapsed subscription. The backend
  /// does not distinguish them on purpose, so neither does this.
  membership,

  /// The user has been sent to the payment gateway and has not come back yet.
  ///
  /// A real state rather than a spinner: the app is in the background, the user is in
  /// a bank's app, and they may return by the deep link, by the task switcher, or not
  /// at all. All three need an answer on screen.
  awaitingPayment,
}

/// The whole of the account flow's state.
///
/// ⚠ Every branch below switches on an [ApiErrorCode], never on a message
/// string (`INTERFACES.md` §1). `message` is carried only to be displayed.
@immutable
class AccountFlowState {
  const AccountFlowState({
    this.step = AccountStep.phone,
    this.busy = false,
    this.phone = '',
    this.error,
    this.message,
    this.retryAfterSeconds,
    this.attemptsAllowed,
    this.conflictingDevice,
    this.codeExpiresAt,
    this.plans = const <Plan>[],
  });

  final AccountStep step;
  final bool busy;
  final String phone;

  /// The last error, as a code. Drives what the screen says.
  final ApiErrorCode? error;

  /// The server's own words, displayed verbatim where a human message is
  /// appropriate. **Never** switched on.
  final String? message;

  final int? retryAfterSeconds;
  final int? attemptsAllowed;
  final ConflictingDevice? conflictingDevice;
  final DateTime? codeExpiresAt;

  /// What the user may buy. Empty until `GET /plans` answers, and the membership
  /// screen says so rather than inventing a price.
  final List<Plan> plans;

  AccountFlowState copyWith({
    AccountStep? step,
    bool? busy,
    String? phone,
    ApiErrorCode? error,
    String? message,
    int? retryAfterSeconds,
    int? attemptsAllowed,
    ConflictingDevice? conflictingDevice,
    DateTime? codeExpiresAt,
    List<Plan>? plans,
    bool clearError = false,
    bool clearConflict = false,
  }) =>
      AccountFlowState(
        step: step ?? this.step,
        busy: busy ?? this.busy,
        phone: phone ?? this.phone,
        error: clearError ? null : (error ?? this.error),
        message: clearError ? null : (message ?? this.message),
        retryAfterSeconds:
            clearError ? null : (retryAfterSeconds ?? this.retryAfterSeconds),
        attemptsAllowed: attemptsAllowed ?? this.attemptsAllowed,
        conflictingDevice: clearConflict
            ? null
            : (conflictingDevice ?? this.conflictingDevice),
        codeExpiresAt: codeExpiresAt ?? this.codeExpiresAt,
        plans: plans ?? this.plans,
      );
}

/// Drives phone → code → session, and every way that can go wrong.
class AccountFlowController extends StateNotifier<AccountFlowState> {
  AccountFlowController(
    this._repository,
    this._onAdmitted, {
    DeepLinkService? deepLinks,
    UrlOpener? openUrl,
  })  : _openUrl = openUrl ?? _defaultOpener,
        super(const AccountFlowState()) {
    if (deepLinks != null) {
      _linkSub = deepLinks.callbacks.listen((PaymentCallback _) {
        // ⚠ The callback's own `result` is deliberately IGNORED. `INTERFACES.md` §7
        // calls the link "a wake-up signal only", and SPEC.md §4 makes the backend the
        // sole authority on whether a payment succeeded. Whatever the link claims, the
        // app asks the server.
        unawaited(_claimAfterPayment());
      });

      // Drain a link that arrived before anything was listening — the app was killed
      // while the user was at the gateway and the link relaunched it.
      //
      // ⚠ On that path `_paymentToken` is gone, because it is memory-only, so
      // `_claimAfterPayment` returns immediately and the user lands on phone entry.
      // THAT IS THE INTENDED OUTCOME, not a hole: their payment already activated the
      // subscription server-side, so signing in by SMS returns a session directly
      // (R3, "if they have a subscriptions and they tryna log in again, they dont need
      // to pay"). It costs one SMS and never costs them the money. Persisting a
      // purchase-authorising token across a kill to save that SMS is a worse trade.
      unawaited(
        deepLinks.consumeInitialLink().then((PaymentCallback? initial) {
          if (initial != null) unawaited(_claimAfterPayment());
        }),
      );
    }
  }

  final AccountRepository _repository;
  final UrlOpener _openUrl;
  StreamSubscription<PaymentCallback>? _linkSub;

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  /// Called once a session exists. The gate re-runs its launch decision rather
  /// than being told the answer, so the admitted path is exercised by exactly
  /// the same code at login as at cold start.
  final void Function() _onAdmitted;

  /// Held in MEMORY only (`INTERFACES.md` §2) — never written to storage, and
  /// dropped the moment the flow restarts.
  String? _otpToken;

  /// The payment-scoped token. Memory only, for the same reason: it authorises a
  /// purchase, and it is worthless the moment the session it earns exists.
  String? _paymentToken;

  /// `POST /auth/send-code`.
  Future<void> sendCode(String phone) async {
    if (state.busy) return;
    state = state.copyWith(busy: true, phone: phone, clearError: true);
    try {
      final SendCodeResult result = await _repository.sendCode(phone);
      _otpToken = result.otpToken;
      state = state.copyWith(
        step: AccountStep.code,
        busy: false,
        attemptsAllowed: result.attemptsAllowed,
        codeExpiresAt: result.expiresAt,
        clearError: true,
      );
    } on ApiException catch (e) {
      state = _failure(e, step: AccountStep.phone);
    }
  }

  /// `POST /auth/verify-code`.
  Future<void> submitCode(String code) async {
    final String? token = _otpToken;
    if (state.busy) return;
    if (token == null) {
      // No token means the flow was restarted underneath us. Sending them back
      // to phone entry is the only honest move.
      state = state.copyWith(
          step: AccountStep.phone, error: ApiErrorCode.otpExpired);
      return;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final VerifyCodeResult result = await _repository.verifyCode(
        otpToken: token,
        code: code,
        phone: state.phone,
      );
      _afterVerify(result);
    } on ApiException catch (e) {
      state = _failure(e, step: AccountStep.code);
    }
  }

  /// `POST /auth/force-login` — the one deliberate device-transfer path.
  ///
  /// ⚠ Needs a FRESH code, so this re-sends one and returns the user to code
  /// entry rather than taking over on a tap. Without a new SMS proof, anyone
  /// holding a stolen handset could evict the real owner.
  Future<void> beginForceLogin() async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final SendCodeResult result = await _repository.sendCode(state.phone);
      _otpToken = result.otpToken;
      state = state.copyWith(
        step: AccountStep.code,
        busy: false,
        attemptsAllowed: result.attemptsAllowed,
        codeExpiresAt: result.expiresAt,
        clearError: true,
      );
      _forcing = true;
    } on ApiException catch (e) {
      state = _failure(e, step: AccountStep.conflict);
    }
  }

  /// True once the user has chosen to take the account over, so the next code
  /// submission goes to `/auth/force-login` instead of `/auth/verify-code`.
  bool _forcing = false;
  bool get isForcing => _forcing;

  Future<void> submitForceLoginCode(String code) async {
    final String? token = _otpToken;
    if (state.busy || token == null) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final VerifyCodeResult result = await _repository.forceLogin(
        otpToken: token,
        code: code,
        phone: state.phone,
      );
      _forcing = false;
      _afterVerify(result);
    } on ApiException catch (e) {
      state = _failure(e, step: AccountStep.code);
    }
  }

  /// Back to the beginning, dropping the OTP token.
  void restart() {
    _otpToken = null;
    _paymentToken = null;
    _forcing = false;
    state = AccountFlowState(phone: state.phone, plans: state.plans);
  }

  /// Sends the user to the gateway.
  ///
  /// The app does NOT wait on a network call to find out what happened; it hands off
  /// and waits for the deep link, or for the user to come back by hand.
  Future<void> startPayment(String planCode) async {
    final String? token = _paymentToken;
    if (state.busy || token == null) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final PaymentStart start =
          await _repository.startPayment(planCode: planCode, bearer: token);
      final Uri? url = Uri.tryParse(start.paymentUrl);
      if (url == null || !await _openUrl(url)) {
        // No browser, or a URL we cannot parse. Failing loudly beats a dead button.
        state = state.copyWith(
          busy: false,
          error: ApiErrorCode.paymentFailed,
          message: 'Could not open the payment page.',
        );
        return;
      }
      state = state.copyWith(step: AccountStep.awaitingPayment, busy: false);
    } on ApiException catch (e) {
      state = _failure(e, step: AccountStep.membership);
    }
  }

  /// "I have paid" — either the deep link fired, or the user tapped the manual button
  /// after returning through the task switcher.
  ///
  /// Both routes run the SAME code, because the deep link is not guaranteed: the user
  /// can always come back by hand, and a flow that only works when the link fires would
  /// strand them holding a paid subscription.
  Future<void> checkPayment() => _claimAfterPayment();

  Future<void> _claimAfterPayment() async {
    final String? token = _paymentToken;
    if (token == null) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final VerifyCodeResult result = await _repository.claimSession(
        paymentToken: token,
        phone: state.phone,
      );
      if (result.next == VerifyNext.session) {
        _paymentToken = null;
        state = state.copyWith(busy: false, clearError: true);
        _onAdmitted();
        return;
      }
      // Still not paid, as far as the SERVER is concerned — which is the only opinion
      // that counts. A fresh token comes back so a slow payment cannot strand the user
      // behind one that expired at the gateway.
      _paymentToken = result.paymentToken ?? token;
      state = state.copyWith(
        step: AccountStep.membership,
        busy: false,
        error: ApiErrorCode.paymentNotVerified,
      );
    } on ApiException catch (e) {
      state = _failure(e, step: AccountStep.membership);
    }
  }

  /// Loads public pricing. Failure is silent by design: the membership screen renders
  /// without a price rather than blocking on it, and the gateway shows the amount
  /// again before any money moves.
  Future<void> loadPlans() async {
    try {
      state = state.copyWith(plans: await _repository.plans());
    } on ApiException {
      /* leave `plans` empty; the screen handles it */
    }
  }

  void _afterVerify(VerifyCodeResult result) {
    _otpToken = null; // single use, whatever happened next
    switch (result.next) {
      case VerifyNext.session:
        state = state.copyWith(busy: false, clearError: true);
        _onAdmitted();
      case VerifyNext.paymentRequired:
        // The token is what makes the membership screen able to do anything at all.
        _paymentToken = result.paymentToken;
        state = state.copyWith(
          step: AccountStep.membership,
          busy: false,
          clearError: true,
        );
        unawaited(loadPlans());
    }
  }

  /// The single place an error becomes a screen.
  ///
  /// This is `SPEC.md` §6.2's list of eight states, and it is exhaustive by
  /// construction: every arm switches on the CODE.
  AccountFlowState _failure(ApiException e, {required AccountStep step}) {
    switch (e.code) {
      // Wrong code. Stay put, let them try again.
      case ApiErrorCode.otpInvalid:
        return state.copyWith(
            step: AccountStep.code,
            busy: false,
            error: e.code,
            message: e.message);

      // The code, or the token behind it, is gone. Start over.
      case ApiErrorCode.otpExpired:
      case ApiErrorCode.otpAttemptsExhausted:
        _otpToken = null;
        _forcing = false;
        return state.copyWith(
            step: AccountStep.phone,
            busy: false,
            error: e.code,
            message: e.message);

      // Already signed in elsewhere. Offer the transfer.
      case ApiErrorCode.deviceConflict:
        return state.copyWith(
          step: AccountStep.conflict,
          busy: false,
          error: e.code,
          message: e.message,
          conflictingDevice: e.conflictingDevice,
        );

      // Both mean "pay". The backend collapses them on purpose so a response
      // cannot leak whether a number has ever been a customer.
      case ApiErrorCode.noAccount:
      case ApiErrorCode.subscriptionExpired:
        return state.copyWith(
            step: AccountStep.membership,
            busy: false,
            error: e.code,
            message: e.message);

      // The session is gone server-side. Full logout, back to the start.
      case ApiErrorCode.sessionRevoked:
      case ApiErrorCode.deviceRevoked:
      case ApiErrorCode.unauthorized:
        _otpToken = null;
        return state.copyWith(
            step: AccountStep.phone,
            busy: false,
            error: e.code,
            message: e.message);

      case ApiErrorCode.paymentFailed:
      case ApiErrorCode.paymentNotVerified:
        return state.copyWith(
            step: AccountStep.membership,
            busy: false,
            error: e.code,
            message: e.message);

      // Everything else stays on the screen it happened on: the user can
      // reasonably retry from there.
      case ApiErrorCode.rateLimited:
      case ApiErrorCode.otpSendFailed:
      case ApiErrorCode.validationError:
      case ApiErrorCode.internal:
      case ApiErrorCode.unknown:
      case ApiErrorCode.offline:
        return state.copyWith(
          step: step,
          busy: false,
          error: e.code,
          message: e.message,
          retryAfterSeconds: e.retryAfterSeconds,
        );
    }
  }
}

final accountFlowProvider =
    StateNotifierProvider<AccountFlowController, AccountFlowState>(
  (ref) => AccountFlowController(
    ref.watch(accountRepositoryProvider),
    // Re-runs the launch decision from disk. The freshly saved session is
    // read back and re-evaluated exactly as it would be at a cold start.
    () => ref.invalidate(gateStateProvider),
    deepLinks: ref.watch(deepLinkServiceProvider),
  ),
);
