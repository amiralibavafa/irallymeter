import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// Always-on header clock (HH:mm:ss, 24-hour). Self-contained: it owns a 1 Hz
/// timer and only ever rebuilds itself, so dropping it into any header costs
/// nothing elsewhere. Used at the top-left of every screen so the current time
/// is visible across the whole app.
class AppClock extends StatefulWidget {
  const AppClock({super.key, this.fontSize = 18});

  final double fontSize;

  @override
  State<AppClock> createState() => _AppClockState();
}

class _AppClockState extends State<AppClock> {
  Timer? _timer;
  late DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    // Tick once a second; tabular figures keep the width stable as digits change.
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
    final colors = InstrumentColors.of(context);
    return Text(
      Formatters.clock(_now),
      style: TextStyle(
        color: colors.primary,
        fontSize: widget.fontSize,
        fontWeight: FontWeight.w700,
        letterSpacing: 1,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
