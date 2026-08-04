import 'dart:convert';

import '../../distance/domain/motion_sample.dart';
import '../../gps/domain/gps_sample.dart';

/// One line of a recorded drive (SPEC-v2 §20.1).
///
/// The trace is the seam that makes §19's accuracy targets testable without
/// driving the route again: record the raw stream once, replay it into the
/// Distance Engine on every code change.
///
/// ## Why timestamps are relative
///
/// Every event carries `offsetMs` — milliseconds from the start of the trace,
/// not a wall clock. A trace recorded in Tehran in August replays identically
/// in a CI container in January, and a fixture's expected distance is a
/// property of the file rather than of when it is run. [TracePlayer] rebuilds
/// absolute `DateTime`s from an arbitrary epoch.
///
/// ## Format
///
/// JSON Lines — one self-describing object per line, discriminated by `t`:
///
/// ```
/// {"t":"gps","ms":0,"lat":35.6892,"lon":51.389,"spd":23.6,"spdAcc":0.4,...}
/// {"t":"motion","ms":20,"ua":[0.1,0,0],"g":[0,0,-9.81],"gy":[0,0,0]}
/// ```
///
/// Line-oriented on purpose: a recording interrupted by a crash or a battery
/// pull is still a valid trace up to its last complete line, which is exactly
/// the recording most worth having.
///
/// Pure Dart — `dart:convert` only. No plugins, no `dart:io`. The recorder
/// hands lines to an injected sink so file access stays outside the domain.
sealed class TraceEvent {
  const TraceEvent(this.offsetMs);

  /// Milliseconds since the start of the trace.
  final int offsetMs;

  Map<String, Object?> toJson();

  String toJsonLine() => jsonEncode(toJson());

  /// Parse one line. Returns null for blank lines, comments (`#`), and
  /// unrecognised event types, so an older reader can replay a newer trace
  /// instead of refusing it.
  static TraceEvent? tryParse(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;

    final ms = _int(decoded['ms']);
    if (ms == null) return null;

    return switch (decoded['t']) {
      'gps' => GpsTraceEvent._fromJson(ms, decoded),
      'motion' => MotionTraceEvent._fromJson(ms, decoded),
      _ => null,
    };
  }

  /// Parse a whole trace, dropping unparseable lines.
  static List<TraceEvent> parseAll(Iterable<String> lines) {
    final out = <TraceEvent>[];
    for (final line in lines) {
      final e = tryParse(line);
      if (e != null) out.add(e);
    }
    out.sort((a, b) => a.offsetMs.compareTo(b.offsetMs));
    return out;
  }

  static int? _int(Object? v) => switch (v) {
        final int i => i,
        final double d when d.isFinite => d.round(),
        _ => null,
      };

  static double _double(Object? v, double fallback) => switch (v) {
        final num n when n.isFinite => n.toDouble(),
        _ => fallback,
      };

  static Vec3 _vec(Object? v) {
    if (v is! List || v.length < 3) return Vec3.zero;
    return Vec3(_double(v[0], 0), _double(v[1], 0), _double(v[2], 0));
  }

  static List<double> _vecJson(Vec3 v) => [v.x, v.y, v.z];
}

/// A recorded location fix.
class GpsTraceEvent extends TraceEvent {
  const GpsTraceEvent({
    required int offsetMs,
    required this.latitude,
    required this.longitude,
    required this.speedMps,
    required this.speedAccuracyMps,
    required this.headingDeg,
    required this.accuracyM,
    required this.altitudeM,
    required this.hasFix,
  }) : super(offsetMs);

  final double latitude;
  final double longitude;

  /// Raw GNSS Doppler speed (m/s). May be negative or NaN — that is the point:
  /// a trace records what the receiver actually said, including when it said
  /// something unusable. SPEC-v2 §7.1's invalidation rules are what interpret it.
  final double speedMps;

  /// Reported uncertainty on [speedMps] (m/s). NaN when the platform gave none.
  ///
  /// Recorded from the first version of this format even though nothing reads
  /// it yet: SPEC-v2 §7.1 invalidates a speed whose accuracy is worse than
  /// 2 m/s, so every fixture would otherwise have to be regenerated the moment
  /// that rule lands.
  final double speedAccuracyMps;

  final double headingDeg;
  final double accuracyM;
  final double altitudeM;
  final bool hasFix;

  GpsSample toSample(DateTime epoch) => GpsSample(
        timestamp: epoch.add(Duration(milliseconds: offsetMs)),
        latitude: latitude,
        longitude: longitude,
        speedMps: speedMps,
        headingDeg: headingDeg,
        accuracyM: accuracyM,
        altitudeM: altitudeM,
        hasFix: hasFix,
      );

  static GpsTraceEvent _fromJson(int ms, Map<String, Object?> j) => GpsTraceEvent(
        offsetMs: ms,
        latitude: TraceEvent._double(j['lat'], 0),
        longitude: TraceEvent._double(j['lon'], 0),
        speedMps: TraceEvent._double(j['spd'], double.nan),
        speedAccuracyMps: TraceEvent._double(j['spdAcc'], double.nan),
        headingDeg: TraceEvent._double(j['hdg'], double.nan),
        accuracyM: TraceEvent._double(j['acc'], -1),
        altitudeM: TraceEvent._double(j['alt'], 0),
        hasFix: j['fix'] != false,
      );

  @override
  Map<String, Object?> toJson() => {
        't': 'gps',
        'ms': offsetMs,
        'lat': latitude,
        'lon': longitude,
        'spd': _nullable(speedMps),
        'spdAcc': _nullable(speedAccuracyMps),
        'hdg': _nullable(headingDeg),
        'acc': accuracyM,
        'alt': altitudeM,
        'fix': hasFix,
      };

  /// JSON has no NaN. A missing key round-trips back to NaN via the parser's
  /// fallback, which is what "the platform reported nothing" should mean.
  static Object? _nullable(double v) => v.isFinite ? v : null;
}

/// A recorded motion reading, in the device frame.
class MotionTraceEvent extends TraceEvent {
  const MotionTraceEvent({
    required int offsetMs,
    required this.userAccel,
    required this.gravity,
    required this.gyro,
  }) : super(offsetMs);

  final Vec3 userAccel;
  final Vec3 gravity;
  final Vec3 gyro;

  MotionSample toSample(DateTime epoch) => MotionSample(
        timestamp: epoch.add(Duration(milliseconds: offsetMs)),
        userAccel: userAccel,
        gravity: gravity,
        gyro: gyro,
      );

  static MotionTraceEvent _fromJson(int ms, Map<String, Object?> j) =>
      MotionTraceEvent(
        offsetMs: ms,
        userAccel: TraceEvent._vec(j['ua']),
        gravity: TraceEvent._vec(j['g']),
        gyro: TraceEvent._vec(j['gy']),
      );

  @override
  Map<String, Object?> toJson() => {
        't': 'motion',
        'ms': offsetMs,
        'ua': TraceEvent._vecJson(userAccel),
        'g': TraceEvent._vecJson(gravity),
        'gy': TraceEvent._vecJson(gyro),
      };
}
