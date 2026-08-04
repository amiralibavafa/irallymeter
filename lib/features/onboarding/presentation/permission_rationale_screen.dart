import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/di/providers.dart';
import '../../../core/storage/storage_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../gps/presentation/providers/gps_providers.dart';

/// Shown ONCE, before the system permission dialogs (P3).
///
/// ## Why this exists
///
/// Verified live on a fresh install: the user saw a blank grey screen, then
/// Android's location dialog, then the notification dialog, with no explanation
/// in between. Two problems with that.
///
/// The practical one: a location prompt with no context is the single most
/// commonly denied permission there is, and a denied location does not degrade
/// this app — it ends it. GPS is not a feature of a trip computer, it is the
/// instrument. The same for notifications: Android needs `POST_NOTIFICATIONS`
/// for the foreground-service notification, and without the foreground service
/// the trip counter freezes the moment the screen goes off, which on a stage is
/// worse than the app refusing to start.
///
/// The policy one: both Google Play and Apple require a rationale to be shown
/// before a location prompt when location is used in the background, and a
/// cold prompt is a documented rejection reason on both stores.
///
/// ## What it deliberately does not do
///
/// It does not enforce anything. If the user denies either permission the app
/// still opens and degrades honestly — the status bar already reads GPS LOST.
/// The `onboarded` flag is therefore set once the user has been THROUGH this
/// screen, not once they have granted something, because re-showing it would
/// be nagging rather than explaining.
///
/// It also never gates `runApp`. That was `P1`: awaiting permissions before the
/// first frame meant one throw could stop the app from ever starting. The
/// requests happen here, inside a live widget with a visible failure path.
class PermissionRationaleScreen extends ConsumerStatefulWidget {
  const PermissionRationaleScreen({super.key});

  @override
  ConsumerState<PermissionRationaleScreen> createState() =>
      _PermissionRationaleScreenState();
}

class _PermissionRationaleScreenState
    extends ConsumerState<PermissionRationaleScreen> {
  bool _busy = false;

  Future<void> _continue() async {
    if (_busy) return;
    setState(() => _busy = true);

    // Sequential, never concurrent: two overlapping requests are what threw
    // `PermissionHandler.PermissionManager, 'A request for permissions is
    // already running'` on the very first run. Each is independently guarded so
    // a failure in one cannot swallow the other.
    try {
      // Through the DI seam, not `GeolocatorGpsService()` directly: the rest of
      // the app already resolves the repository this way, and constructing the
      // concrete service here would reach past the simulated-drive override as
      // well as making this path untestable.
      await ref.read(gpsRepositoryProvider).ensurePermission();
    } catch (_) {
      // The screen's whole promise is that the app opens either way.
    }
    try {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
    } catch (_) {
      // Same.
    }

    if (!mounted) return;

    // Order matters here.
    //
    // The in-memory gate is flipped as well as the stored flag: storage is only
    // read at startup, so persisting alone would leave the app root holding the
    // GPS engine back for the whole of THIS launch, and the user would arrive
    // at a cluster that measures nothing until they restarted it.
    //
    // And the flush is NOT awaited. Hive updates its in-memory copy
    // synchronously, so the value reads back immediately either way; all that
    // blocking would buy is a driver watching a spinner for a file write. If
    // the write itself failed, the only consequence is that the rationale
    // appears once more on the next launch — which is the harmless direction.
    ref.read(onboardedProvider.notifier).state = true;
    unawaited(ref.read(storageProvider).write(StorageKeys.onboarded, true));
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.base,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            // Scrollable on purpose. Unlike the cluster this is not an
            // instrument panel, so on a short landscape screen scrolling is the
            // right answer and an overflow is not.
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'iRallyMeter',
                    style: TextStyle(
                      color: AppColors.accent,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Two permissions before you drive',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 15),
                  ),
                  const SizedBox(height: 22),
                  const _Reason(
                    icon: Icons.satellite_alt,
                    color: AppColors.ok,
                    title: 'LOCATION',
                    body: 'Distance is measured from GPS. Without location this '
                        'app cannot count a single metre, because there is no '
                        'other source for it.',
                  ),
                  const SizedBox(height: 14),
                  const _Reason(
                    icon: Icons.notifications_active_outlined,
                    color: AppColors.warn,
                    title: 'NOTIFICATIONS',
                    body: 'Android needs this to keep the trip recording while '
                        'the screen is off. It is not an alert you have to '
                        'read. Deny it and the counter can freeze mid-stage.',
                  ),
                  const SizedBox(height: 14),
                  const _Reason(
                    icon: Icons.lock_outline,
                    color: AppColors.info,
                    title: 'WHERE IT GOES',
                    body: 'Nowhere. There is no account, no analytics and no '
                        'server. Trips stay on this phone. The only thing the '
                        'app ever downloads is map tiles, and only while the '
                        'map screen is open.',
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton(
                      onPressed: _busy ? null : _continue,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: AppColors.black,
                        disabledBackgroundColor: AppColors.surfaceRaised,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: Text(
                        _busy ? 'ASKING…' : 'CONTINUE',
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'You can change either of these later in Android Settings, '
                    'and the app still opens if you say no.',
                    style: TextStyle(color: AppColors.textDim, fontSize: 12.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Reason extends StatelessWidget {
  const _Reason({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1),
                ),
                const SizedBox(height: 5),
                Text(
                  body,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
