import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/utils/geo_math.dart';
import '../../../compass/presentation/providers/compass_providers.dart';
import 'instrument_box.dart';

/// CAP heading: large 3-digit value + cardinal + a minimal fixed needle whose
/// rose rotates. Heading is already EMA-smoothed upstream, so no implicit
/// animation is needed (avoids extra rebuild churn).
class HeadingDisplay extends ConsumerWidget {
  const HeadingDisplay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final heading = ref.watch(capHeadingProvider);
    final source = ref.watch(headingSourceProvider);
    final colors = InstrumentColors.of(context);
    final valid = heading.isFinite;

    return InstrumentBox(
      label: 'CAP  •  $source',
      child: Row(
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: CustomPaint(
              painter: _CompassPainter(
                heading: valid ? heading : 0,
                color: colors.primary,
                accent: colors.accent,
                active: valid,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                valid ? Formatters.heading(heading) : '---',
                style: TextStyle(
                  color: colors.primary,
                  fontSize: 40,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                valid ? GeoMath.cardinal(heading) : '--',
                style: TextStyle(color: colors.accent, fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CompassPainter extends CustomPainter {
  _CompassPainter({
    required this.heading,
    required this.color,
    required this.accent,
    required this.active,
  });

  final double heading;
  final Color color;
  final Color accent;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 2;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = active ? color.withValues(alpha: 0.4) : AppColors.textDim;
    canvas.drawCircle(c, r, ring);

    if (!active) return;

    // Rotate the rose so current heading is up; draw a fixed accent needle up.
    final rad = -heading * math.pi / 180.0;
    // North marker on the rose.
    final nPaint = Paint()..color = accent;
    final nx = c.dx + r * math.sin(rad + math.pi); // north points opposite when heading up
    final ny = c.dy - r * math.cos(rad + math.pi);
    canvas.drawCircle(Offset(nx, ny), 3.5, nPaint);

    // Fixed forward needle (vehicle direction), always pointing up.
    final needle = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(c, Offset(c.dx, c.dy - r + 4), needle);
  }

  @override
  bool shouldRepaint(covariant _CompassPainter old) =>
      old.heading != heading || old.active != active || old.color != color;
}
