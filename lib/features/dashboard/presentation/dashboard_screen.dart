import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_clock.dart';
import '../../settings/presentation/providers/settings_providers.dart';
import '../../trip/domain/trip_state.dart';
import '../../average_speed/presentation/widgets/average_speed_display.dart';
import 'widgets/gps_status_bar.dart';
import 'widgets/speed_display.dart';
import 'widgets/trip_controls.dart';
import 'widgets/trip_panel.dart';

/// Rally dashboard — the always-on primary screen. Critical data (speed, trip,
/// heading, GPS health) is visible at all times. Layout adapts to orientation;
/// landscape is the co-driver configuration.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locked = ref.watch(isLockedProvider);

    return Scaffold(
      backgroundColor: AppColors.base,
      body: SafeArea(
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  _TopBar(),
                  const SizedBox(height: 10),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final landscape = c.maxWidth > c.maxHeight;
                        return landscape ? const _LandscapeLayout() : const _PortraitLayout();
                      },
                    ),
                  ),
                ],
              ),
            ),
            if (locked) const _LockOverlay(),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.read(settingsProvider.notifier);
    final night = ref.watch(isNightProvider);
    final colors = InstrumentColors.of(context);

    Widget iconBtn(IconData icon, VoidCallback onTap, {Color? color}) => IconButton(
          onPressed: onTap,
          icon: Icon(icon, color: color ?? colors.primary, size: 26),
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        );

    return Row(
      children: [
        const AppClock(),
        const SizedBox(width: 12),
        // Deliberately NOT Flexible. On a narrow portrait screen the clock plus
        // five 48 px nav targets already over-subscribe the bar, so letting the
        // badge shrink starves it to a bare icon — and an unreadable GPS/Tunnel
        // status is far worse than a clipped nav icon on a tool whose whole job
        // is telling the co-driver whether the distance can be trusted.
        // The badge keeps its natural width; the pre-existing portrait overflow
        // is tracked in dashboard_layout_test.dart.
        const GpsStatusBar(),
        const Spacer(),
        iconBtn(night ? Icons.dark_mode : Icons.light_mode, settings.toggleDisplayMode),
        iconBtn(Icons.timer_outlined, () => context.push('/timer')),
        iconBtn(Icons.map_outlined, () => context.push('/map')),
        iconBtn(Icons.settings_outlined, () => context.push('/settings')),
        iconBtn(Icons.lock_outline, settings.toggleLock, color: AppColors.accent),
      ],
    );
  }
}

class _LandscapeLayout extends StatelessWidget {
  const _LandscapeLayout();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Hero speed — biggest possible.
        Expanded(
          flex: 5,
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.divider),
            ),
            child: const Center(child: SpeedDisplay()),
          ),
        ),
        const SizedBox(width: 10),
        // Instruments column.
        Expanded(
          flex: 4,
          child: Column(
            children: [
              const Expanded(child: TripReadout(counter: TripCounter.a)),
              const SizedBox(height: 8),
              const Expanded(child: TripReadout(counter: TripCounter.b)),
              const SizedBox(height: 8),
              Expanded(
                child: Row(
                  children: const [
                    Expanded(child: AverageSpeedDisplay()),
                    SizedBox(width: 8),
                    Expanded(child: OdometerReadout()),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const TripControls(counter: TripCounter.a),
            ],
          ),
        ),
      ],
    );
  }
}

class _PortraitLayout extends StatelessWidget {
  const _PortraitLayout();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          flex: 4,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.divider),
            ),
            child: const Center(child: SpeedDisplay()),
          ),
        ),
        const SizedBox(height: 8),
        const Expanded(flex: 2, child: TripReadout(counter: TripCounter.a)),
        const SizedBox(height: 8),
        Expanded(
          flex: 2,
          child: Row(
            children: const [
              Expanded(child: TripReadout(counter: TripCounter.b)),
              SizedBox(width: 8),
              Expanded(child: AverageSpeedDisplay()),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const OdometerReadout(),
        const SizedBox(height: 8),
        const TripControls(counter: TripCounter.a),
      ],
    );
  }
}

/// Lock mode: absorbs all touches except a long-press in the corner to unlock,
/// preventing accidental trip resets/edits while driving.
class _LockOverlay extends ConsumerWidget {
  const _LockOverlay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {}, // swallow taps
        child: Stack(
          children: [
            Positioned(
              top: 8,
              right: 8,
              child: GestureDetector(
                onLongPress: () => ref.read(settingsProvider.notifier).setLocked(false),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceRaised,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.accent),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock, color: AppColors.accent, size: 18),
                      SizedBox(width: 8),
                      Text('HOLD TO UNLOCK',
                          style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
