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
              // The orientation decision is made ONCE, here, because the top bar
              // needs it too: in portrait the bar is over-subscribed and stacks.
              child: LayoutBuilder(
                builder: (context, c) {
                  final landscape = c.maxWidth > c.maxHeight;
                  return Column(
                    children: [
                      _TopBar(landscape: landscape),
                      const SizedBox(height: 10),
                      Expanded(
                        child: landscape
                            ? const _LandscapeLayout()
                            : const _PortraitLayout(),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (locked) const _LockOverlay(),
          ],
        ),
      ),
    );
  }
}

/// The header: clock, measurement status, and the nav targets.
///
/// ## Why portrait stacks and landscape does not (P2)
///
/// The bar is over-subscribed in portrait and always was. On a 465 px logical
/// width, 10 px of padding each side leaves 445, and the contents want
/// clock (~88) + gap (12) + status badge (up to ~225 when it reads
/// `TUNNEL · EST 0.00`) + five 48 px nav targets (240) = ~565. Measured live it
/// overflowed by 70 px normally, 79 px on `GPS SYNC` and **137 px in Estimation
/// Mode** — it grew with the status text, which is exactly when the co-driver
/// most needs to read it.
///
/// Every way of closing that on ONE row costs something that matters:
/// shrinking the touch targets breaks glove operation, ellipsising the badge
/// hides whether the distance can be trusted, and hiding nav behind a menu adds
/// a tap while moving. Portrait has 1038 px of height and the instruments below
/// are flex-sized, so a second row costs ~56 px of a dimension we have plenty
/// of and nothing at all of the ones we do not.
///
/// Landscape is 1018 px wide, has never overflowed in day or night, and is the
/// co-driver configuration the cluster is designed around — so it is left
/// exactly as it was.
class _TopBar extends ConsumerWidget {
  const _TopBar({required this.landscape});

  final bool landscape;

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

    final nav = <Widget>[
      iconBtn(night ? Icons.dark_mode : Icons.light_mode, settings.toggleDisplayMode),
      iconBtn(Icons.timer_outlined, () => context.push('/timer')),
      iconBtn(Icons.map_outlined, () => context.push('/map')),
      iconBtn(Icons.settings_outlined, () => context.push('/settings')),
      iconBtn(Icons.lock_outline, settings.toggleLock, color: AppColors.accent),
    ];

    if (landscape) {
      return Row(
        children: [
          const AppClock(),
          const SizedBox(width: 12),
          // Deliberately NOT Flexible here. Landscape has the width for the
          // badge at its natural size, and an unreadable GPS/Tunnel status is
          // far worse than a clipped nav icon on a tool whose whole job is
          // telling the co-driver whether the distance can be trusted.
          const GpsStatusBar(),
          const Spacer(),
          ...nav,
        ],
      );
    }

    return Column(
      children: [
        Row(
          children: const [
            AppClock(),
            SizedBox(width: 12),
            // Flexible ONLY in portrait, and only as a last resort: with 445 px
            // available and the clock taking 100, the badge has ~345 against a
            // natural ~225, so it renders in full in every state seen on the
            // road. This exists so a freak long value ellipsises instead of
            // overflowing — it is a floor, not the normal case.
            Flexible(child: GpsStatusBar()),
          ],
        ),
        const SizedBox(height: 6),
        // Spread rather than packed: with a whole row to themselves the targets
        // are further apart than they were, which is the point on a moving car.
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: nav),
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
