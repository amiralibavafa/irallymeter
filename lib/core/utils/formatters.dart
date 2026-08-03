/// Display formatters. Kept allocation-light: these run on every GPS tick.
enum SpeedUnit { kmh, mph }

extension SpeedUnitLabel on SpeedUnit {
  String get label => this == SpeedUnit.kmh ? 'KM/H' : 'MPH';
  String get storageKey => this == SpeedUnit.kmh ? 'kmh' : 'mph';
  static SpeedUnit fromStorage(String s) =>
      s == 'mph' ? SpeedUnit.mph : SpeedUnit.kmh;
}

class Formatters {
  Formatters._();

  static const double _msToKmh = 3.6;
  static const double _msToMph = 2.2369362920544;
  static const double _mToMi = 0.000621371192;

  /// Convert m/s to the chosen display unit (rounded int, no decimals — a
  /// rally speedometer is read at a glance, decimals add noise).
  static int speed(double mps, SpeedUnit unit) {
    final v = unit == SpeedUnit.kmh ? mps * _msToKmh : mps * _msToMph;
    if (v < 0 || v.isNaN) return 0;
    return v.round();
  }

  /// Distance in metres → odometer string.
  /// Under 1000 m shows whole metres ("847 m"); above shows km with 2 dp,
  /// matching how rally road books reference distances.
  static String distance(double meters, {required bool metric}) {
    if (metric) {
      if (meters < 1000) return '${meters.round()} m';
      return '${(meters / 1000).toStringAsFixed(2)} km';
    } else {
      final miles = meters * _mToMi;
      if (miles < 0.1) return '${(meters * 3.28084).round()} ft';
      return '${miles.toStringAsFixed(2)} mi';
    }
  }

  /// Trip readout used in the big trip panel — always 2 dp km/mi so the
  /// number width is stable.
  static String trip(double meters, {required bool metric}) {
    final v = metric ? meters / 1000 : meters * _mToMi;
    return v.toStringAsFixed(2);
  }

  static String tripUnit({required bool metric}) => metric ? 'KM' : 'MI';

  /// Distance to metre resolution ("1.590 km"). Rally tunnel legs are short, so
  /// the trip readout's 2 dp would round away the metres that matter here.
  static String distancePrecise(double meters, {required bool metric}) {
    final v = metric ? meters / 1000 : meters * _mToMi;
    return '${v.toStringAsFixed(3)} ${metric ? 'km' : 'mi'}';
  }

  /// Elapsed time as m:ss (or h:mm:ss past an hour) — how a co-driver calls a
  /// tunnel time. No tenths: this is a read-back value, not a stage time.
  static String legTime(Duration d) {
    final abs = d.abs();
    final h = abs.inHours;
    final m = abs.inMinutes.remainder(60);
    final s = abs.inSeconds.remainder(60);
    return h > 0 ? '$h:${_p(m)}:${_p(s)}' : '$m:${_p(s)}';
  }

  /// Speed with one decimal ("60.1") — tunnel averages are compared closely
  /// enough that the speedometer's whole-unit rounding loses real information.
  static String speedPrecise(double mps, SpeedUnit unit) {
    final v = unit == SpeedUnit.kmh ? mps * _msToKmh : mps * _msToMph;
    if (v < 0 || v.isNaN) return '0.0';
    return v.toStringAsFixed(1);
  }

  /// Heading as a zero-padded 3-digit "CAP" value (rally co-driver heading).
  static String heading(double deg) =>
      ((deg % 360).round() % 360).toString().padLeft(3, '0');

  /// Accuracy in metres for the GPS status badge.
  static String accuracy(double m) =>
      m.isNaN || m <= 0 ? '--' : '±${m.round()}m';

  /// Stopwatch / stage time mm:ss.t (tenths) — co-driver reads tenths.
  static String stopwatch(Duration d) {
    final neg = d.isNegative;
    final abs = d.abs();
    final h = abs.inHours;
    final m = abs.inMinutes.remainder(60);
    final s = abs.inSeconds.remainder(60);
    final tenths = (abs.inMilliseconds.remainder(1000) ~/ 100);
    final core = h > 0
        ? '$h:${_p(m)}:${_p(s)}.$tenths'
        : '${_p(m)}:${_p(s)}.$tenths';
    return neg ? '-$core' : core;
  }

  /// Wall-clock time of day as HH:mm:ss (24-hour, zero-padded). Used by the
  /// global header clock.
  static String clock(DateTime t) => '${_p(t.hour)}:${_p(t.minute)}:${_p(t.second)}';

  static String _p(int n) => n.toString().padLeft(2, '0');
}
