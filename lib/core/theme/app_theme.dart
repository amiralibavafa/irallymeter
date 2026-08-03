import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';

/// Display brightness modes. "Day" = max contrast white, "Night" = dimmed
/// amber to preserve night vision during stages.
enum DisplayMode { day, night }

class AppTheme {
  AppTheme._();

  /// Tabular figures + heavy weight read as a digital instrument cluster.
  /// We rely on the platform's default font with `fontFeatures` tabular
  /// figures so digits never shift width as numbers change (critical for a
  /// speedometer that updates at 10 Hz).
  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  static ThemeData build(DisplayMode mode) {
    final bool night = mode == DisplayMode.night;
    final Color primary = night ? AppColors.nightTextPrimary : AppColors.textPrimary;
    final Color secondary = night ? AppColors.nightTextSecondary : AppColors.textSecondary;
    final Color accent = night ? AppColors.nightAccent : AppColors.accent;

    final base = ThemeData.dark(useMaterial3: true);

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.base,
      colorScheme: base.colorScheme.copyWith(
        surface: AppColors.surface,
        primary: accent,
        secondary: accent,
        error: AppColors.danger,
        onSurface: primary,
      ),
      dividerColor: AppColors.divider,
      textTheme: _textTheme(primary, secondary),
      iconTheme: IconThemeData(color: primary),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.base,
        foregroundColor: primary,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      extensions: <ThemeExtension<dynamic>>[
        InstrumentColors(
          primary: primary,
          secondary: secondary,
          accent: accent,
          night: night,
        ),
      ],
    );
  }

  static TextTheme _textTheme(Color primary, Color secondary) {
    TextStyle digital(double size, FontWeight w) => TextStyle(
          color: primary,
          fontSize: size,
          fontWeight: w,
          height: 1.0,
          letterSpacing: -1,
          fontFeatures: _tabular,
        );
    return TextTheme(
      // Giant speed readout.
      displayLarge: digital(180, FontWeight.w700),
      displayMedium: digital(120, FontWeight.w700),
      displaySmall: digital(72, FontWeight.w700),
      headlineMedium: digital(48, FontWeight.w600),
      titleLarge: TextStyle(color: primary, fontSize: 22, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(color: primary, fontSize: 18),
      bodyMedium: TextStyle(color: secondary, fontSize: 15),
      labelLarge: TextStyle(
        color: secondary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.5,
      ),
    );
  }
}

/// Theme extension so widgets can read instrument-specific colors without
/// hard-coding day/night branches everywhere.
class InstrumentColors extends ThemeExtension<InstrumentColors> {
  const InstrumentColors({
    required this.primary,
    required this.secondary,
    required this.accent,
    required this.night,
  });

  final Color primary;
  final Color secondary;
  final Color accent;
  final bool night;

  @override
  InstrumentColors copyWith({Color? primary, Color? secondary, Color? accent, bool? night}) {
    return InstrumentColors(
      primary: primary ?? this.primary,
      secondary: secondary ?? this.secondary,
      accent: accent ?? this.accent,
      night: night ?? this.night,
    );
  }

  @override
  InstrumentColors lerp(ThemeExtension<InstrumentColors>? other, double t) {
    if (other is! InstrumentColors) return this;
    return InstrumentColors(
      primary: Color.lerp(primary, other.primary, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      night: t < 0.5 ? night : other.night,
    );
  }

  static InstrumentColors of(BuildContext context) =>
      Theme.of(context).extension<InstrumentColors>()!;
}
