import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../data/account_repository.dart';
import 'account_flow_screen.dart';
import 'providers/account_providers.dart';

/// The account gate. Wraps the rally computer and decides whether to show it.
///
/// ══ WHY IT IS A WRAPPER AND NOT A ROUTE ══
///
/// Saam, on the app itself: *"the app wont be and cant be touched as the team
/// approved it… we are only creating that gate i mentioned"*. A route would
/// mean editing `app_router.dart` and `app.dart`; a wrapper means neither file
/// changes. It also means the GPS engine physically cannot start behind the
/// login screen, because `IRallyMeterApp` — which starts it — is never built
/// until this widget returns [child].
///
/// ══ THE INVARIANT ══
///
/// `SPEC.md` §4: *"the speedometer never awaits a network call."*
///
/// ⇒ The only thing awaited here is [AccountRepository.restore], which reads
///   secure storage and verifies a signature. **No HTTP.** A token refresh or
///   a membership check on this path would each look reasonable and each would
///   break the invariant, so `test/account_gate_test.dart` builds this widget
///   with an API client that THROWS on any call and asserts the app renders.
class AccountGate extends ConsumerWidget {
  const AccountGate({required this.child, super.key});

  /// The rally computer. Built only once the gate admits.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(gateStateProvider).when(
          // Reading a few keys out of the keystore. Typically a few frames, and
          // deliberately not a branded splash: a spinner that flashes is worse
          // than a plain surface that does not.
          loading: () => const _GateSurface(child: SizedBox.shrink()),

          // `restore()` is written not to throw, but a keystore can fail on a
          // locked-down device. Falling back to the login flow is recoverable;
          // a red error screen at launch is not.
          error: (Object _, StackTrace __) =>
              const _GateSurface(child: AccountFlowScreen()),

          data: (GateState state) {
            switch (state.decision) {
              case GateDecision.admitted:
                return child;
              case GateDecision.needsLogin:
                return const _GateSurface(child: AccountFlowScreen());
              case GateDecision.misconfigured:
                return const _GateSurface(child: _MisconfiguredScreen());
            }
          },
        );
  }
}

/// The account screens' own `MaterialApp`.
///
/// `IRallyMeterApp` has its own, and the two are never mounted at once — the
/// gate returns one or the other.
///
/// ⚠ Pinned to [DisplayMode.day] rather than following the persisted setting,
/// which keeps the gate independent of Hive and therefore of `storageProvider`.
/// Defensible because entitlement is evaluated at session start only
/// (`INTERFACES.md` §5), so the account screens are only ever reached at
/// launch, never mid-stage. Both modes share the same dark surfaces; only the
/// text colour differs.
class _GateSurface extends StatelessWidget {
  const _GateSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'iRallyMeter',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(DisplayMode.day),
        home: child,
      );
}

/// No API base URL was compiled in.
///
/// A build problem, and shown as one. The alternative was a login screen that
/// can never succeed, which reads to a user as "the app is broken" and to a
/// tester as "the server is down".
class _MisconfiguredScreen extends StatelessWidget {
  const _MisconfiguredScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.base,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.settings_ethernet,
                    color: AppColors.warn, size: 40),
                const SizedBox(height: 24),
                Text('BUILD NOT CONFIGURED',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                const Text(
                  'This build has no API address, so signing in cannot work. '
                  'Rebuild with IRALLYMETER_API_BASE_URL set.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 15,
                      height: 1.45),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
