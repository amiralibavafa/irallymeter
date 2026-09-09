import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/account_repository.dart';
import '../domain/api_error.dart';
import '../domain/session.dart';
import 'providers/account_providers.dart';

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
      );
}

/// Drives phone → code → session, and every way that can go wrong.
class AccountFlowController extends StateNotifier<AccountFlowState> {
  AccountFlowController(this._repository, this._onAdmitted)
      : super(const AccountFlowState());

  final AccountRepository _repository;

  /// Called once a session exists. The gate re-runs its launch decision rather
  /// than being told the answer, so the admitted path is exercised by exactly
  /// the same code at login as at cold start.
  final void Function() _onAdmitted;

  /// Held in MEMORY only (`INTERFACES.md` §2) — never written to storage, and
  /// dropped the moment the flow restarts.
  String? _otpToken;

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
    _forcing = false;
    state = AccountFlowState(phone: state.phone);
  }

  void _afterVerify(VerifyCodeResult result) {
    _otpToken = null; // single use, whatever happened next
    switch (result.next) {
      case VerifyNext.session:
        state = state.copyWith(busy: false, clearError: true);
        _onAdmitted();
      case VerifyNext.paymentRequired:
        state = state.copyWith(
          step: AccountStep.membership,
          busy: false,
          clearError: true,
        );
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
  ),
);
