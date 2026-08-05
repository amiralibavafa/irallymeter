import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/formatters.dart';
import '../../../distance/presentation/providers/distance_providers.dart';
import '../../../gps/domain/gps_sample.dart';
import '../../../gps/presentation/providers/gps_providers.dart';
import '../../../settings/presentation/providers/settings_providers.dart';

/// Compact GPS health strip: fix quality dot + accuracy.
///
/// Also the co-driver's one indicator of WHERE the distance is coming from, so
/// it reports the distance engine's source, not just raw GPS health:
///
///   • `GPS ±5m`            — normal, distance is GPS ground truth.
///   • `TUNNEL · EST 0.42`  — GPS unavailable, distance is being estimated;
///                            shows the estimated distance so far, because
///                            "estimating" alone doesn't tell you how far you
///                            have to trust it.
///   • `GPS SYNC`           — recovered; a correction is being paid out.
///
/// Deliberately never blank: an ambiguous status is worse than a bad one.
class GpsStatusBar extends ConsumerWidget {
  const GpsStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tunnel = ref.watch(tunnelModeProvider);
    final reconciling = ref.watch(reconcilingProvider);
    final dropped = ref.watch(gpsDropoutProvider).valueOrNull ?? true;
    final quality = ref.watch(fixQualityProvider);
    // C14: a FAILED stream must not read the same as a quiet one.
    final failed = ref.watch(gpsStreamErrorProvider) != null;
    final accuracy = ref.watch(accuracyProvider);
    final tunnelMeters =
        ref.watch(distanceEngineProvider.select((s) => s.tunnelMeters));
    final metric = ref.watch(isMetricProvider);

    final (color, icon, text) = _status(
      tunnel: tunnel,
      reconciling: reconciling,
      dropped: dropped,
      failed: failed,
      quality: quality,
      accuracy: accuracy,
      tunnelMeters: tunnelMeters,
      metric: metric,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          // Ellipsise rather than overflow when the top bar is tight — the
          // status text varies in length and must never break the layout.
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // The accuracy figure and the tunnel estimate both live in this
              // string and both change every second.
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                fontFeatures: AppTheme.tabularFigures,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Ordered by what the co-driver most needs to know: estimating outranks fix
  /// quality, because the quality is meaningless when we are not using it.
  (Color, IconData, String) _status({
    required bool tunnel,
    required bool reconciling,
    required bool dropped,
    required bool failed,
    required FixQuality quality,
    required double accuracy,
    required double tunnelMeters,
    required bool metric,
  }) {
    if (tunnel) {
      final est = Formatters.trip(tunnelMeters, metric: metric);
      return (AppColors.warn, Icons.hourglass_bottom, 'TUNNEL · EST $est');
    }
    if (reconciling) {
      return (AppColors.info, Icons.sync, 'GPS SYNC');
    }
    // Checked BEFORE the dropout branch, because a failed stream also looks
    // dropped and "GPS LOST" would send the crew looking for sky when the
    // receiver is not the problem. A tunnel is silence; this is not.
    if (failed) {
      return (AppColors.danger, Icons.gps_off, 'GPS ERROR');
    }
    if (dropped || quality == FixQuality.none) {
      return (AppColors.danger, Icons.satellite_alt, 'GPS LOST');
    }
    final label = Formatters.accuracy(accuracy);
    return switch (quality) {
      FixQuality.good => (AppColors.ok, Icons.satellite_alt, 'GPS $label'),
      FixQuality.fair => (AppColors.warn, Icons.satellite_alt, 'GPS $label'),
      FixQuality.poor => (AppColors.warn, Icons.satellite_alt, 'WEAK $label'),
      FixQuality.none => (AppColors.danger, Icons.satellite_alt, 'GPS LOST'),
    };
  }
}
