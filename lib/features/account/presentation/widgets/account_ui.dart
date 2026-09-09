import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';

/// The shared look for the account screens.
///
/// ══ WHY THIS FILE EXISTS ══
///
/// `ARCHITECTURE.md` §11.0: **`app_theme.dart` styles TYPE and COLOUR only.**
/// There is no `FilledButtonTheme`, no `OutlinedButtonTheme`, no
/// `TextButtonTheme` and — the one that bites hardest here — **no
/// `InputDecorationTheme`**. A `TextField` dropped into this app inherits
/// Material's defaults, which look nothing like the rest of the cluster.
///
/// So the CTA is COPIED VERBATIM from the one precedent in the app
/// (`permission_rationale_screen.dart:187-207`) and the input style is
/// authored once, here, beside the screens that use it. **`app_theme.dart` is
/// not touched** — adding component themes to it would restyle every existing
/// screen, which is exactly the kind of change `CLAUDE.md` §3 forbids.

/// The primary call to action.
///
/// ⚠ Busy state changes the **label**, never a spinner. That is the app's own
/// precedent (`_busy ? 'ASKING…' : 'CONTINUE'`), and it is the better
/// behaviour here too: the button keeps its size, so nothing reflows under a
/// thumb that is already moving toward it.
class AccountCta extends StatelessWidget {
  const AccountCta({
    required this.label,
    required this.busyLabel,
    required this.onPressed,
    this.busy = false,
    super.key,
  });

  final String label;

  /// Shown while [busy]. `SENDING…`, `VERIFYING…`, `PAYING…`.
  final String busyLabel;

  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: AppColors.black,
          disabledBackgroundColor: AppColors.surfaceRaised,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(
          busy ? busyLabel : label,
          style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2),
        ),
      ),
    );
  }
}

/// The secondary action. Built from the app's existing `OutlinedButton` usage
/// rather than invented: six already exist, all with the same flat treatment.
class AccountSecondaryAction extends StatelessWidget {
  const AccountSecondaryAction({
    required this.label,
    required this.onPressed,
    this.danger = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Force Login revokes another device. It is destructive, and it is coloured
  /// like it.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color colour = danger ? AppColors.danger : AppColors.textSecondary;
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: colour,
          side: BorderSide(color: colour.withValues(alpha: 0.5)),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(
          label,
          style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0),
        ),
      ),
    );
  }
}

/// The one input style in the app, authored here because the theme defines
/// none. Flat, high contrast, and large enough to hit while parked.
InputDecoration accountInputDecoration({
  required String label,
  String? hint,
  String? errorText,
  Widget? prefix,
}) {
  OutlineInputBorder border(Color colour, double width) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colour, width: width),
      );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    errorText: errorText,
    prefixIcon: prefix,
    filled: true,
    fillColor: AppColors.surfaceRaised,
    contentPadding:
        const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
    labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 15),
    hintStyle: const TextStyle(color: AppColors.textDim, fontSize: 15),
    errorStyle: const TextStyle(color: AppColors.danger, fontSize: 13),
    enabledBorder: border(AppColors.divider, 1),
    focusedBorder: border(AppColors.accent, 2),
    errorBorder: border(AppColors.danger, 1),
    focusedErrorBorder: border(AppColors.danger, 2),
  );
}

/// A screen heading. `titleLarge` is 22/w600 in the theme; the eyebrow above it
/// uses `labelLarge`'s 13/w600/ls-1.5 treatment.
class AccountHeading extends StatelessWidget {
  const AccountHeading({required this.eyebrow, required this.title, this.body, super.key});

  final String eyebrow;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          eyebrow,
          style: const TextStyle(
            color: AppColors.accent,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
          ),
        ),
        // 12 under a label, per the spacing rule measured in §11.3.
        const SizedBox(height: 12),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        if (body != null) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            body!,
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 15, height: 1.45),
          ),
        ],
      ],
    );
  }
}

/// An inline problem, in the app's existing card idiom: a raised surface with
/// `EdgeInsets.all(14)`.
class AccountNotice extends StatelessWidget {
  const AccountNotice({
    required this.icon,
    required this.colour,
    required this.message,
    super.key,
  });

  final IconData icon;
  final Color colour;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colour.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: colour, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 15, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// A countdown, e.g. "RESEND IN 42s".
///
/// ⚠ Carries [AppTheme.tabularFigures] deliberately. §11.2 records that five
/// live readouts lost tabular figures by building their own [TextStyle]; a
/// digit column that jitters once a second is exactly that mistake again.
class AccountCountdown extends StatelessWidget {
  const AccountCountdown({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
        label,
        style: const TextStyle(
          color: AppColors.textDim,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.5,
          fontFeatures: AppTheme.tabularFigures,
        ),
      );
}

/// The common page frame: dark base, centred, comfortable reading width,
/// scrollable so a keyboard never overflows a screen.
class AccountScaffold extends StatelessWidget {
  const AccountScaffold({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.base,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
