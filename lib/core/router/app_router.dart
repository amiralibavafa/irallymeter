import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/dashboard/presentation/dashboard_screen.dart';
import '../../features/map/presentation/map_screen.dart';
import '../../features/distance/presentation/section_log_screen.dart';
import '../../features/onboarding/presentation/permission_rationale_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/stage_timer/presentation/stage_timer_screen.dart';
import '../di/providers.dart';

/// Central route table. Dashboard is the home; everything else is pushed on top
/// so the back gesture always returns to the cluster.
class AppRouter {
  AppRouter._();

  /// [onboarded] decides only where the app STARTS. It is read once, at
  /// construction, rather than watched: the flag flips exactly once, and
  /// re-routing a driver mid-stage because a stored value changed would be a
  /// worse behaviour than the one it fixed.
  /// Where the app starts. Extracted so it can be asserted on its own:
  /// constructing a `GoRouter` needs a live binding, which makes the one
  /// decision in this file otherwise untestable without pumping a widget.
  static String initialLocationFor({required bool onboarded}) =>
      onboarded ? '/' : '/welcome';

  static GoRouter build({required bool onboarded}) => GoRouter(
        initialLocation: initialLocationFor(onboarded: onboarded),
        routes: [
          GoRoute(path: '/', builder: (context, state) => const DashboardScreen()),
          GoRoute(
              path: '/welcome',
              builder: (context, state) => const PermissionRationaleScreen()),
          GoRoute(path: '/map', builder: (context, state) => const MapScreen()),
          GoRoute(path: '/timer', builder: (context, state) => const StageTimerScreen()),
          GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
          GoRoute(
              path: '/sections',
              builder: (context, state) => const SectionLogScreen()),
        ],
      );
}

/// The app's single router instance. A `Provider` so it is built exactly once
/// even though the app root rebuilds on every day/night theme change — a router
/// rebuilt inside `build()` would reset the navigation stack under the driver.
final routerProvider = Provider<GoRouter>(
    (ref) => AppRouter.build(onboarded: ref.read(onboardedProvider)));
