import 'dart:math' as math;

import 'geo_math.dart';

/// Time-based angular smoother (the compass equivalent of the fix `[3.7]` made
/// to the speed display).
///
/// The compass used a fixed per-sample weight of 0.2, applied on every
/// magnetometer event. That makes the needle's lag a property of whatever rate
/// the device's magnetometer happens to run at: `τ = Δt / -ln(1 - 0.2)`, which
/// is about **4.5 sample intervals**. At `sensors_plus`'s default 200 ms that is
/// τ ≈ 0.9 s and roughly 2.7 s to settle — and a different number on every
/// handset. That is the reported "laggy, has a delay".
///
/// Deriving the weight from elapsed time instead makes the lag a property of
/// the clock, so the needle behaves the same on every phone.
class AngleSmoother {
  AngleSmoother(this.tau);

  /// Time constant. Larger = steadier and slower.
  final Duration tau;

  double _value = double.nan;
  DateTime? _lastAt;

  double get value => _value;
  bool get isSeeded => !_value.isNaN;

  double add(double deg, DateTime at) {
    if (!deg.isFinite) return _value;

    final last = _lastAt;
    _lastAt = at;

    if (_value.isNaN || last == null) {
      _value = (deg + 360.0) % 360.0;
      return _value;
    }

    final dt = at.difference(last);
    // Out-of-order or duplicate timestamps: hold rather than jump.
    if (dt <= Duration.zero) return _value;

    // A long gap means the old reading carries no information — snap.
    final a = 1 - math.exp(-dt.inMicroseconds / tau.inMicroseconds);
    _value = GeoMath.smoothAngle(_value, deg, a.clamp(0.0, 1.0));
    return _value;
  }

  void reset() {
    _value = double.nan;
    _lastAt = null;
  }
}
