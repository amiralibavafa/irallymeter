import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/formatters.dart';
import '../../../settings/presentation/providers/settings_providers.dart';
import '../../../trip/presentation/providers/trip_providers.dart';
import '../providers/tunnel_providers.dart';

/// Manual tunnel start/end pad plus the last measurement.
///
/// Matches the existing cluster idiom: one glove-friendly 56 px button in the
/// same style as the trip correction pad, alongside a read-back of the result.
/// While recording it shows a live elapsed/distance readout so the driver can
/// see the leg accruing; once ended it holds the completed figures.
///
/// Height is pinned to the button. The cluster stacks this under three
/// `Expanded` instrument tiles, so any extra height here is taken straight out
/// of the trip readouts — letting the summary text wrap freely starved them to
/// the point of overflowing on a short landscape phone.
class TunnelControls extends ConsumerWidget {
  const TunnelControls({super.key});

  /// Matches the trip correction pad's touch target.
  static const double height = 56;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recording = ref.watch(tunnelRecordingProvider);

    return SizedBox(
      height: height,
      child: Row(
        children: [
          _TunnelButton(recording: recording),
          const SizedBox(width: 8),
          const Expanded(child: _TunnelSummary()),
        ],
      ),
    );
  }
}

class _TunnelButton extends ConsumerWidget {
  const _TunnelButton({required this.recording});

  final bool recording;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = recording ? AppColors.danger : AppColors.accent;
    final notifier = ref.read(tunnelProvider.notifier);

    return Material(
      color: AppColors.surfaceRaised,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: recording ? notifier.markEnd : notifier.markStart,
        // Long-press to abandon a mis-tap without recording a bogus leg.
        onLongPress: recording ? notifier.cancel : null,
        child: Container(
          height: 56,
          width: 150,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(recording ? Icons.stop_circle_outlined : Icons.play_circle_outline,
                  color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                recording ? 'TUNNEL END' : 'TUNNEL',
                style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Live leg while recording, completed result afterwards, hint when idle.
class _TunnelSummary extends ConsumerWidget {
  const _TunnelSummary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tunnel = ref.watch(tunnelProvider);
    final colors = InstrumentColors.of(context);

    if (tunnel.recording) return const _LiveLeg();

    final result = tunnel.last;
    if (result == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Mark a tunnel to measure its distance, time and average.',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: colors.secondary, fontSize: 13),
        ),
      );
    }

    final metric = ref.watch(isMetricProvider);
    final unit = ref.watch(speedUnitProvider);
    return _Figures(
      label: 'LAST TUNNEL',
      distance: Formatters.distancePrecise(result.distanceMeters, metric: metric),
      time: Formatters.legTime(result.duration),
      speed: '${Formatters.speedPrecise(result.averageMps, unit)} ${unit.label.toLowerCase()}',
      color: colors.primary,
    );
  }
}

/// The in-progress leg.
///
/// Owns a 1 Hz timer and only rebuilds itself — the same self-contained pattern
/// [AppClock] uses. The elapsed value is derived from the marker's wall-clock
/// anchor rather than counted up, so it stays correct across backgrounding
/// (matching how the stage timer survives suspension).
class _LiveLeg extends ConsumerStatefulWidget {
  const _LiveLeg();

  @override
  ConsumerState<_LiveLeg> createState() => _LiveLegState();
}

class _LiveLegState extends ConsumerState<_LiveLeg> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final start = ref.watch(tunnelProvider.select((s) => s.start));
    if (start == null) return const SizedBox.shrink();

    final metric = ref.watch(isMetricProvider);
    final meters = ref.watch(tripAProvider) - start.distanceMeters;

    return _Figures(
      label: 'RECORDING',
      distance: Formatters.distancePrecise(meters > 0 ? meters : 0, metric: metric),
      time: Formatters.legTime(_now.difference(start.at)),
      speed: null,
      color: AppColors.accent,
    );
  }
}

/// Shared three-figure read-back: distance · time · average.
class _Figures extends StatelessWidget {
  const _Figures({
    required this.label,
    required this.distance,
    required this.time,
    required this.speed,
    required this.color,
  });

  final String label;
  final String distance;
  final String time;
  final String? speed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = InstrumentColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              _fig(distance, colors.primary),
              _sep(colors.secondary),
              _fig(time, colors.primary),
              if (speed != null) ...[
                _sep(colors.secondary),
                _fig(speed!, colors.primary),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _fig(String v, Color c) => Text(
        v,
        style: TextStyle(
          color: c,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );

  Widget _sep(Color c) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text('·', style: TextStyle(color: c, fontSize: 18)),
      );
}
