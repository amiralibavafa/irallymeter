import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../domain/api_error.dart';
import '../domain/session.dart';
import 'account_flow_controller.dart';
import 'widgets/account_ui.dart';

/// The account flow: phone, code, device conflict, membership.
///
/// Every screen here is built from `ARCHITECTURE.md` §11's inventory: the CTA
/// is the app's one precedent copied verbatim, the input style is authored in
/// `account_ui.dart` because the theme defines none, and spacing follows the
/// measured rule of 24 between sections, 12 under a label, 14 inside a card.
class AccountFlowScreen extends ConsumerStatefulWidget {
  const AccountFlowScreen({this.startAtMembership = false, super.key});

  /// Open on the membership screen instead of phone entry. Set by the gate when a
  /// stored session's subscription has lapsed.
  final bool startAtMembership;

  @override
  ConsumerState<AccountFlowScreen> createState() => _AccountFlowScreenState();
}

class _AccountFlowScreenState extends ConsumerState<AccountFlowScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.startAtMembership) {
      // After the first frame: the controller cannot be mutated during a build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(accountFlowProvider.notifier).showRenewal();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
      case AccountStep.awaitingPayment:
        return const _AwaitingPaymentView();
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
    case ApiErrorCode.forceLoginCooldown:
      // Force Login is capped at once per 24 hours so one subscription cannot be
      // passed around. The server's message carries the remaining hours.
      return state.message ??
          'This account was moved to another phone recently. Try again later.';
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
      // The master spec's wording, verbatim.
      return 'Payment unsuccessful. Please try again.';
    case ApiErrorCode.paymentNotVerified:
      // Reached when the server still sees no live subscription. Deliberately not
      // "payment failed": a gateway can confirm late, and telling someone their money
      // vanished when it has not is worse than telling them to wait.
      return 'We have not seen the payment confirmed yet. If you have just '
          'paid, wait a moment and try again.';
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
          label: 'CONTINUE',
          busyLabel: 'SENDING…',
          busy: state.busy,
          onPressed: () => _submit(_controller.text),
        ),
        const SizedBox(height: 12),
        // "Not a member? Get Membership". It runs the SAME path as Continue, because
        // the server decides: a number with no live subscription is answered with
        // PAYMENT_REQUIRED and lands on the membership screen by itself. Presenting it
        // as a separate route would be a lie in the UI about how the system works.
        Center(
          child: TextButton(
            onPressed: state.busy ? null : () => _submit(_controller.text),
            child: const Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: 'Not a member? ',
                    style: TextStyle(color: AppColors.textDim, fontSize: 14),
                  ),
                  TextSpan(
                    text: 'Get Membership',
                    style: TextStyle(
                      color: AppColors.accent,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            TextButton(
              onPressed: state.busy ? null : () => _forceLogin(_controller.text),
              child: const Text(
                'FORCE LOGIN',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            IconButton(
              onPressed: () => _explainForceLogin(context),
              icon: const Icon(Icons.info_outline,
                  color: AppColors.textDim, size: 18),
              tooltip: 'What is Force Login?',
            ),
          ],
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

  void _forceLogin(String value) {
    final String phone = value.trim();
    if (phone.isEmpty) return;
    ref.read(accountFlowProvider.notifier).beginForceLoginWith(phone);
  }

  /// The info icon the master spec asks for beside Force Login.
  ///
  /// It says what the button COSTS, not just what it does: it signs the other phone
  /// out, and it cannot be used again for 24 hours.
  void _explainForceLogin(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Force Login', style: TextStyle(color: AppColors.textPrimary)),
        content: const Text(
          'Use this if your subscription is signed in on a phone you no longer '
          'have.\n\nWe send a code to your number, then move the subscription to '
          'this phone and sign the other one out.\n\nIt can only be used once '
          'every 24 hours.',
          style: TextStyle(color: AppColors.textSecondary, height: 1.45),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('GOT IT', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
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
    final Plan? plan = state.plans.isEmpty ? null : state.plans.first;

    return AccountScaffold(
      children: <Widget>[
        const AccountHeading(
          eyebrow: 'MEMBERSHIP',
          title: 'This number needs a subscription',
          // The backend collapses "never subscribed" and "lapsed" into one answer on
          // purpose, so the copy cannot claim to know which it is.
          body: 'A subscription unlocks the rally computer on this phone.',
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.divider),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      // The master spec names one package: "iRallyMeter Pro".
                      (plan?.name ?? 'iRallyMeter Pro').toUpperCase(),
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      // No price until GET /plans answers. Saying so beats inventing
                      // one, and the gateway shows the amount again anyway.
                      // Price comes from runtime config first (so a change needs no new
                      // APK), then the plan, then the documented default. It is never
                      // computed here and never shown as zero.
                      '${state.config?.formattedPrice ?? plan?.formattedToman ?? "400,000"} Toman',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        // A price is a number that must not jitter while it loads.
                        fontFeatures: AppTheme.tabularFigures,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                  '${plan?.days ?? 30} DAYS',
                  style: const TextStyle(
                    color: AppColors.textDim,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                    fontFeatures: AppTheme.tabularFigures,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        AccountCta(
          label: 'PAY NOW',
          busyLabel: 'PAYING…',
          busy: state.busy,
          // Disabled by the SERVER's kill switch, not by a local flag.
          onPressed: state.config?.paymentEnabled == false
              ? null
              : () => controller.startPayment(plan?.code ?? 'monthly'),
        ),
        const SizedBox(height: 12),
        // The master spec puts "I Have Paid" on the membership screen as well as on the
        // waiting screen: a user who paid and came back through the task switcher may
        // never see the waiting screen at all.
        AccountSecondaryAction(
          label: 'I HAVE PAID',
          onPressed: state.busy ? null : controller.checkPayment,
        ),
        const SizedBox(height: 12),
        const Text(
          'Payment opens in your browser and returns here when it is done.',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: AppColors.textDim, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 12),
        AccountSecondaryAction(
          label: 'BACK',
          onPressed: state.busy ? null : controller.restart,
        ),
        _noticeFor(state),
      ],
    );
  }
}

// ── waiting for the gateway ──────────────────────────────────────────────────

/// The user is at the bank. This screen exists because the return trip is not
/// guaranteed to be the deep link.
///
/// ⚠ THE MANUAL BUTTON IS NOT A FALLBACK, IT IS A SECOND FIRST-CLASS PATH. A user can
/// always come back through the task switcher instead of tapping the browser's return,
/// and on that path no deep link ever fires. A flow that only worked when the link
/// fired would strand someone who had genuinely paid. Both routes call exactly the same
/// method.
class _AwaitingPaymentView extends ConsumerWidget {
  const _AwaitingPaymentView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AccountFlowState state = ref.watch(accountFlowProvider);
    final AccountFlowController controller =
        ref.read(accountFlowProvider.notifier);

    return AccountScaffold(
      children: <Widget>[
        const AccountHeading(
          eyebrow: 'PAYMENT',
          title: 'Finish in your browser',
          body: 'When the payment is done you come straight back here. If you '
              'return another way, tap the button below.',
        ),
        const SizedBox(height: 24),
        const AccountNotice(
          icon: Icons.verified_user_outlined,
          colour: AppColors.info,
          // Worth saying out loud: it is why a cancelled payment cannot be faked, and
          // why the app is not simply believing the browser.
          message: 'Your subscription is activated by our server after the '
              'gateway confirms the payment, never by this app.',
        ),
        const SizedBox(height: 24),
        AccountCta(
          label: 'I HAVE PAID',
          busyLabel: 'CHECKING…',
          busy: state.busy,
          onPressed: controller.checkPayment,
        ),
        const SizedBox(height: 12),
        AccountSecondaryAction(
          label: 'BACK',
          onPressed: state.busy ? null : controller.restart,
        ),
        _noticeFor(state),
      ],
    );
  }
}
