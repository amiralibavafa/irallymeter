import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../domain/api_error.dart';
import 'account_flow_controller.dart';
import 'widgets/account_ui.dart';

/// The account flow: phone, code, device conflict, membership.
///
/// Every screen here is built from `ARCHITECTURE.md` §11's inventory: the CTA
/// is the app's one precedent copied verbatim, the input style is authored in
/// `account_ui.dart` because the theme defines none, and spacing follows the
/// measured rule of 24 between sections, 12 under a label, 14 inside a card.
class AccountFlowScreen extends ConsumerWidget {
  const AccountFlowScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AccountFlowState state = ref.watch(accountFlowProvider);
    switch (state.step) {
      case AccountStep.phone:
        return const _PhoneView();
      case AccountStep.code:
        return const _CodeView();
      case AccountStep.conflict:
        return const _ConflictView();
      case AccountStep.membership:
        return const _MembershipView();
    }
  }
}

/// Turns an error code into something a driver can act on.
///
/// ⚠ Switches on the CODE only. The server's `message` is shown as a second
/// line where one exists, but nothing here parses it (`INTERFACES.md` §1).
String? _explain(AccountFlowState state) {
  switch (state.error) {
    case null:
      return null;
    case ApiErrorCode.otpInvalid:
      return 'That code is not right. Check the SMS and try again.';
    case ApiErrorCode.otpExpired:
      return 'That code expired. Request a new one.';
    case ApiErrorCode.otpAttemptsExhausted:
      return 'Too many wrong attempts. Request a new code.';
    case ApiErrorCode.otpSendFailed:
      return 'The code could not be sent. Try again in a moment.';
    case ApiErrorCode.rateLimited:
      final int? wait = state.retryAfterSeconds;
      return wait == null
          ? 'Too many requests. Wait a moment and try again.'
          : 'Too many requests. Try again in $wait seconds.';
    case ApiErrorCode.offline:
      return 'No connection. The rally computer still works offline; '
          'signing in is the only thing that needs a network.';
    case ApiErrorCode.sessionRevoked:
      return 'This session was ended. Sign in again.';
    case ApiErrorCode.deviceRevoked:
      return 'This device was signed out because the account was '
          'moved to another phone.';
    case ApiErrorCode.unauthorized:
      return 'Your session expired. Sign in again.';
    case ApiErrorCode.validationError:
      return 'That does not look like an Iranian mobile number.';
    case ApiErrorCode.deviceConflict:
    case ApiErrorCode.noAccount:
    case ApiErrorCode.subscriptionExpired:
      // These are whole screens, not inline notices.
      return null;
    case ApiErrorCode.paymentFailed:
    case ApiErrorCode.paymentNotVerified:
      return 'The payment was not completed.';
    case ApiErrorCode.internal:
    case ApiErrorCode.unknown:
      return 'Something went wrong. Try again.';
  }
}

Widget _noticeFor(AccountFlowState state) {
  final String? text = _explain(state);
  if (text == null) return const SizedBox.shrink();
  final bool soft = state.error == ApiErrorCode.offline ||
      state.error == ApiErrorCode.rateLimited;
  return Padding(
    padding: const EdgeInsets.only(top: 24),
    child: AccountNotice(
      icon: soft ? Icons.wifi_off : Icons.error_outline,
      colour: soft ? AppColors.warn : AppColors.danger,
      message: text,
    ),
  );
}

// ── phone ────────────────────────────────────────────────────────────────────

class _PhoneView extends ConsumerStatefulWidget {
  const _PhoneView();

  @override
  ConsumerState<_PhoneView> createState() => _PhoneViewState();
}

class _PhoneViewState extends ConsumerState<_PhoneView> {
  late final TextEditingController _controller =
      TextEditingController(text: ref.read(accountFlowProvider).phone);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AccountFlowState state = ref.watch(accountFlowProvider);
    return AccountScaffold(
      children: <Widget>[
        const AccountHeading(
          eyebrow: 'SIGN IN',
          title: 'Enter your phone number',
          body: 'We send a code by SMS. Your subscription is tied to this '
              'number and runs on one phone at a time.',
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _controller,
          enabled: !state.busy,
          keyboardType: TextInputType.phone,
          autofillHints: const <String>[AutofillHints.telephoneNumber],
          // The server normalises to E.164, so anything it accepts is allowed
          // through here. Restricting the keyboard to digits and a leading `+`
          // is a convenience, never the validation.
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.allow(RegExp(r'[0-9+]')),
            LengthLimitingTextInputFormatter(24),
          ],
          style: const TextStyle(
              color: AppColors.textPrimary, fontSize: 18, letterSpacing: 1.2),
          decoration: accountInputDecoration(
            label: 'MOBILE NUMBER',
            hint: '09xxxxxxxxx',
            prefix: const Icon(Icons.smartphone, color: AppColors.textDim),
          ),
          onSubmitted: (String v) => _submit(v),
        ),
        const SizedBox(height: 24),
        AccountCta(
          label: 'SEND CODE',
          busyLabel: 'SENDING…',
          busy: state.busy,
          onPressed: () => _submit(_controller.text),
        ),
        _noticeFor(state),
      ],
    );
  }

  void _submit(String value) {
    final String phone = value.trim();
    if (phone.isEmpty) return;
    ref.read(accountFlowProvider.notifier).sendCode(phone);
  }
}

// ── code ─────────────────────────────────────────────────────────────────────

class _CodeView extends ConsumerStatefulWidget {
  const _CodeView();

  @override
  ConsumerState<_CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends ConsumerState<_CodeView> {
  final TextEditingController _controller = TextEditingController();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // One second is enough for a countdown and cheap enough to run on a login
    // screen. It is cancelled in dispose, so it cannot outlive the screen and
    // it never runs while the rally computer is showing.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AccountFlowState state = ref.watch(accountFlowProvider);
    final AccountFlowController controller =
        ref.read(accountFlowProvider.notifier);
    final Duration? left = _remaining(state.codeExpiresAt);

    return AccountScaffold(
      children: <Widget>[
        AccountHeading(
          eyebrow: controller.isForcing ? 'MOVE THIS ACCOUNT' : 'VERIFY',
          title: 'Enter the code',
          body: controller.isForcing
              ? 'Enter the new code to move your subscription to this phone. '
                  'The other device is signed out.'
              : 'Sent by SMS to ${state.phone}.',
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _controller,
          enabled: !state.busy,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          autofillHints: const <String>[AutofillHints.oneTimeCode],
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(10),
          ],
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: 8,
          ),
          decoration: accountInputDecoration(label: 'CODE'),
          onSubmitted: (String v) => _submit(v),
        ),
        const SizedBox(height: 12),
        Center(
          child: AccountCountdown(
            label: left == null
                ? ' '
                : left == Duration.zero
                    ? 'CODE EXPIRED'
                    : 'EXPIRES IN ${_mmss(left)}',
          ),
        ),
        const SizedBox(height: 24),
        AccountCta(
          label: 'VERIFY',
          busyLabel: 'VERIFYING…',
          busy: state.busy,
          onPressed: () => _submit(_controller.text),
        ),
        const SizedBox(height: 12),
        AccountSecondaryAction(
          label: 'USE A DIFFERENT NUMBER',
          onPressed: state.busy ? null : controller.restart,
        ),
        _noticeFor(state),
      ],
    );
  }

  Duration? _remaining(DateTime? expiresAt) {
    if (expiresAt == null) return null;
    final Duration d = expiresAt.difference(DateTime.now().toUtc());
    return d.isNegative ? Duration.zero : d;
  }

  /// Padded so the digits do not jump. Paired with
  /// [AccountCountdown]'s tabular figures, which §11.2 records five live
  /// readouts having lost by building their own TextStyle.
  static String _mmss(Duration d) {
    final String m = d.inMinutes.toString().padLeft(2, '0');
    final String s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _submit(String value) {
    final String code = value.trim();
    if (code.isEmpty) return;
    final AccountFlowController controller =
        ref.read(accountFlowProvider.notifier);
    if (controller.isForcing) {
      controller.submitForceLoginCode(code);
    } else {
      controller.submitCode(code);
    }
  }
}

// ── device conflict ──────────────────────────────────────────────────────────

class _ConflictView extends ConsumerWidget {
  const _ConflictView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AccountFlowState state = ref.watch(accountFlowProvider);
    final AccountFlowController controller =
        ref.read(accountFlowProvider.notifier);
    final ConflictingDevice? other = state.conflictingDevice;

    return AccountScaffold(
      children: <Widget>[
        const AccountHeading(
          eyebrow: 'ALREADY SIGNED IN',
          title: 'This number is on another phone',
          body: 'One subscription runs on one phone at a time. You can move it '
              'here, which signs the other phone out.',
        ),
        const SizedBox(height: 24),
        AccountNotice(
          icon: Icons.phonelink_lock,
          colour: AppColors.warn,
          // deviceName and lastSeen are all the server sends, deliberately:
          // enough to recognise your own phone, not enough to profile it.
          message: other == null
              ? 'Another device is currently signed in.'
              : other.lastSeen == null
                  ? 'Signed in on ${other.deviceName}.'
                  : 'Signed in on ${other.deviceName}, last used '
                      '${_ago(other.lastSeen!)}.',
        ),
        const SizedBox(height: 24),
        AccountCta(
          label: 'MOVE IT TO THIS PHONE',
          busyLabel: 'SENDING…',
          busy: state.busy,
          onPressed: controller.beginForceLogin,
        ),
        const SizedBox(height: 12),
        Text(
          'We send a new code first, so an account can never be moved '
          'without the SMS.',
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: AppColors.textDim, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 12),
        AccountSecondaryAction(
          label: 'CANCEL',
          onPressed: state.busy ? null : controller.restart,
        ),
        _noticeFor(state),
      ],
    );
  }

  static String _ago(DateTime when) {
    final Duration d = DateTime.now().toUtc().difference(when);
    if (d.inMinutes < 2) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} minutes ago';
    if (d.inHours < 24) return '${d.inHours} hours ago';
    return '${d.inDays} days ago';
  }
}

// ── membership ───────────────────────────────────────────────────────────────

class _MembershipView extends ConsumerWidget {
  const _MembershipView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AccountFlowState state = ref.watch(accountFlowProvider);
    final AccountFlowController controller =
        ref.read(accountFlowProvider.notifier);

    return AccountScaffold(
      children: <Widget>[
        const AccountHeading(
          eyebrow: 'MEMBERSHIP',
          title: 'This number needs a subscription',
          // The backend collapses "never subscribed" and "lapsed" into one
          // answer on purpose, so the copy cannot claim to know which it is.
          body: 'Your number is verified. A subscription is needed before the '
              'rally computer unlocks on this phone.',
        ),
        const SizedBox(height: 24),

        // ⚠⚠ HONEST DEAD END, NOT A DISABLED BUTTON PRETENDING TO WORK.
        //
        // `DEVIATIONS.md` D-3 category 2: `/auth/verify-code` answers
        // PAYMENT_REQUIRED with a bare `userId`, `/payment/start` requires a
        // Bearer access token, and nothing mints one from that userId. So the
        // payment call cannot be made from this state by anyone. Showing a
        // PAY button here would be a button that always fails with a 401.
        const AccountNotice(
          icon: Icons.construction,
          colour: AppColors.warn,
          message: 'Payment is not available in this build yet. Please '
              'contact support to activate your subscription.',
        ),
        const SizedBox(height: 24),
        AccountSecondaryAction(
          label: 'BACK',
          onPressed: state.busy ? null : controller.restart,
        ),
        _noticeFor(state),
      ],
    );
  }
}
