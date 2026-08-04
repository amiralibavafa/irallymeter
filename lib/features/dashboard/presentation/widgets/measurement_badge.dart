import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../distance/domain/measurement_status.dart';

/// The SPEC-v2 §5.1 indicator: `EST`, `EST?` or `SYNC` beside a figure that is
/// not a straight measurement.
///
/// Deliberately a separate widget rather than a colour tweak. Colour alone is
/// not an indicator — it fails in sunlight, it fails on a night-mode cluster,
/// and it fails for a colour-blind co-driver. §5.1 asks for a badge NEXT TO the
/// affected values, so the badge is the signal and the colour reinforces it.
///
/// Absent entirely when the reading is measured, so the presence of any badge
/// at all means "do not fully trust this number".
class MeasurementBadge extends StatelessWidget {
  const MeasurementBadge({super.key, required this.status, this.compact = false});

  final MeasurementStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final label = status.badge;
    if (label == null) return const SizedBox.shrink();

    final color = switch (status.state) {
      MeasurementState.reconciling => AppColors.info,
      MeasurementState.estimated =>
        status.isLowConfidence ? AppColors.danger : AppColors.warn,
      MeasurementState.measured => AppColors.warn,
    };

    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 5 : 8, vertical: compact ? 1 : 3),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: compact ? 10 : 14,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
