import 'package:flutter/material.dart';

/// Motorsport instrument palette. Two surfaces only (base + raised) to keep
/// the UI flat and legible under sunlight; semantic colors for status.
class AppColors {
  AppColors._();

  // Base surfaces (day uses the same dark instrument look — rally clusters are
  // dark in all conditions; "day mode" raises brightness/contrast instead).
  static const Color black = Color(0xFF000000);
  static const Color base = Color(0xFF0A0A0B);
  static const Color surface = Color(0xFF161618);
  static const Color surfaceRaised = Color(0xFF1F1F23);
  static const Color divider = Color(0xFF2C2C31);

  // Text
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFAEAEB6);
  static const Color textDim = Color(0xFF6E6E78);

  // Semantic status
  static const Color ok = Color(0xFF2ECC71); // normal / good fix
  static const Color warn = Color(0xFFFFA726); // degraded
  static const Color danger = Color(0xFFFF3B30); // no fix / alert
  static const Color accent = Color(0xFFFF6B00); // rally orange highlight
  static const Color info = Color(0xFF4FC3F7);

  // Night mode dims the whites to protect night vision.
  static const Color nightTextPrimary = Color(0xFFFF5A3C); // amber-red
  static const Color nightTextSecondary = Color(0xFFB23A28);
  static const Color nightAccent = Color(0xFFFF6B00);
}
