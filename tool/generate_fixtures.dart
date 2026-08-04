// Generates the three replay fixtures required by SPEC-v2 §20.1.
//
//   dart run tool/generate_fixtures.dart
//
// The OUTPUT is committed, not generated at test time: a fixture whose content
// depends on when it runs is not a fixture. This script exists so the traces
// are reviewable and reproducible, not so tests can rebuild them.
//
// ## Why the ground truth is exact rather than approximate
//
// Every leg runs due north along a meridian. For constant longitude the
// haversine in GeoMath collapses to `R · Δφ`, so stepping N metres north is
// exactly `N · 180 / (π · R)` degrees of latitude — invertible with no
// projection error and no cos(latitude) term. The expected distance of a
// fixture is therefore a property of how it was built, not a measurement.
//
// That matters: if ground truth were computed with a different earth model
// than `GeoMath._earthRadiusM`, the §19 tests would be measuring the
// disagreement between two spheres instead of the behaviour of the engine.

import 'dart:io';
import 'dart:math' as math;

/// Must match `GeoMath._earthRadiusM`.
const double kEarthRadiusM = 6371000.0;

/// Degrees of latitude per metre travelled due north.
final double kDegPerMetre = 180.0 / (math.pi * kEarthRadiusM);

/// Somewhere unremarkable in Iran, which is where this ships.
const double kStartLat = 35.6892;
const double kStartLon = 51.3890;

/// Deterministic LCG (Numerical Recipes). Used instead of `dart:math`'s Random
/// so regenerating a fixture on a different Dart SDK produces byte-identical
/// output — the whole point of committing them.
class Lcg {
  Lcg(this._state);
  int _state;

  int next() => _state = (_state * 1664525 + 1013904223) & 0xFFFFFFFF;

  /// Uniform in [-1, 1].
  double symmetric() => (next() / 0xFFFFFFFF) * 2.0 - 1.0;
}

String gps({
  required int ms,
  required double lat,
  required double lon,
  required double speed,
  required double speedAcc,
  required double heading,
  required double accuracy,
}) =>
    '{"t":"gps","ms":$ms,"lat":${lat.toStringAsFixed(9)},'
    '"lon":${lon.toStringAsFixed(9)},"spd":${speed.toStringAsFixed(3)},'
    '"spdAcc":${speedAcc.toStringAsFixed(2)},"hdg":${heading.toStringAsFixed(1)},'
    '"acc":${accuracy.toStringAsFixed(1)},"alt":1200.0,"fix":true}';

String motion({required int ms, required double ax}) =>
    '{"t":"motion","ms":$ms,"ua":[${ax.toStringAsFixed(4)},0.0,0.0],'
    '"g":[0.0,0.0,-9.81],"gy":[0.0,0.0,0.0]}';

void write(String name, List<String> lines, String header) {
  final f = File('test/fixtures/$name');
  f.parent.createSync(recursive: true);
  f.writeAsStringSync('# $header\n${lines.join('\n')}\n');
  stdout.writeln('wrote test/fixtures/$name  (${lines.length} events)');
}

// ---------------------------------------------------------------------------
// 1. clean_drive — §19 "Good reception, 50 km ... error ≤ 1.0 %"
// ---------------------------------------------------------------------------
//
// 50.000 km due north at a steady 25 m/s (90 km/h), 1 Hz, 5 m accuracy.
// 2001 fixes: the first only anchors, the remaining 2000 each contribute
// exactly 25 m. Ground truth 50 000.000 m.
void cleanDrive() {
  const stepM = 25.0;
  const steps = 2000;
  final lines = <String>[];
  for (var i = 0; i <= steps; i++) {
    lines.add(gps(
      ms: i * 1000,
      lat: kStartLat + i * stepM * kDegPerMetre,
      lon: kStartLon,
      speed: 25.0,
      speedAcc: 0.5,
      heading: 0.0,
      accuracy: 5.0,
    ));
  }
  write('clean_drive.jsonl', lines,
      'clean_drive · 50000.000 m due north · 25 m/s · 1 Hz · acc 5 m · GROUND TRUTH 50000.0');
}

// ---------------------------------------------------------------------------
// 2. parked_10min — §19 "Vehicle parked for 10 minutes → 0.000 km accumulated"
// ---------------------------------------------------------------------------
//
// 600 fixes at 1 Hz from a stationary vehicle. The position wanders inside a
// ±4 m box — ordinary standstill drift for an 8 m fix, not a pathological case.
//
// The Doppler speed is reported as a small non-zero value the way a real
// receiver does when parked; it never exceeds SPEC-v2 §6.1's 1.5 m/s gate,
// which is precisely the rule that should reject every one of these
// displacements. GROUND TRUTH 0.000 m.
void parked() {
  final rng = Lcg(20260803);
  final lines = <String>[];
  for (var i = 0; i <= 600; i++) {
    final dNorthM = rng.symmetric() * 4.0;
    final dEastM = rng.symmetric() * 4.0;
    lines.add(gps(
      ms: i * 1000,
      lat: kStartLat + dNorthM * kDegPerMetre,
      lon: kStartLon +
          dEastM * kDegPerMetre / math.cos(kStartLat * math.pi / 180.0),
      speed: (rng.symmetric().abs()) * 0.6,
      speedAcc: 1.2,
      heading: 0.0,
      accuracy: 8.0,
    ));
  }
  write('parked_10min.jsonl', lines,
      'parked_10min · stationary, +/-4 m wander, acc 8 m, 600 s · GROUND TRUTH 0.0');
}

// ---------------------------------------------------------------------------
// 3. tunnel_2km — §19 "2 km GPS-free section at roughly steady speed ≤ 3 %"
// ---------------------------------------------------------------------------
//
// 500 m clean approach → 80 s with NO fixes at all (2000.0 m of real travel at
// 25 m/s) → clean exit resuming from the true position.
//
// Motion samples run throughout at 20 Hz with zero longitudinal acceleration —
// a car holding its speed through a tunnel. That is deliberately the case where
// the forward-axis estimator never gains confidence, so SensorDistanceSource
// coasts at the entry speed, which is the §12.1 model doing exactly what it
// claims. GROUND TRUTH 3000.0 m total (500 + 2000 + 500).
void tunnel() {
  const v = 25.0;
  const approachS = 20; // 500 m
  const darkS = 80; // 2000 m
  const exitS = 20; // 500 m
  final lines = <String>[];

  double latAt(double metres) => kStartLat + metres * kDegPerMetre;

  for (var s = 0; s <= approachS; s++) {
    lines.add(gps(
      ms: s * 1000,
      lat: latAt(s * v),
      lon: kStartLon,
      speed: v,
      speedAcc: 0.5,
      heading: 0.0,
      accuracy: 5.0,
    ));
  }

  // No GPS for darkS seconds. Motion continues — this is the only thing the
  // engine has to go on, and the tick heartbeat is what notices the silence.
  final totalMs = (approachS + darkS + exitS) * 1000;
  for (var ms = 0; ms <= totalMs; ms += 50) {
    lines.add(motion(ms: ms, ax: 0.0));
  }

  for (var s = approachS + darkS; s <= approachS + darkS + exitS; s++) {
    lines.add(gps(
      ms: s * 1000,
      lat: latAt(s * v),
      lon: kStartLon,
      speed: v,
      speedAcc: 0.5,
      heading: 0.0,
      accuracy: 5.0,
    ));
  }

  lines.sort((a, b) {
    int msOf(String l) =>
        int.parse(RegExp(r'"ms":(\d+)').firstMatch(l)!.group(1)!);
    return msOf(a).compareTo(msOf(b));
  });

  write('tunnel_2km.jsonl', lines,
      'tunnel_2km · 500 m clean + 80 s dark (2000.0 m @ 25 m/s) + 500 m clean · GROUND TRUTH 3000.0, estimated leg 2000.0');
}

// ---------------------------------------------------------------------------
// 4. tunnel_varying — the case tunnel_2km deliberately cannot cover
// ---------------------------------------------------------------------------
//
// SPEC-v2 §12.2's accelerometer refinement had NEVER RUN inside a full replay.
// tunnel_2km feeds `ax: 0.0` throughout, so the forward-axis estimator never
// gains confidence and SensorDistanceSource correctly falls back to coasting at
// v₀. That fixture is the §12.1 model doing what it claims — and it is
// structurally incapable of exercising §12.2.
//
// This one drives the other half:
//
//   * The APPROACH varies its speed, with accelerometer readings that agree
//     with the GPS speed change. That is the only way the axis estimator learns
//     which way is forward (`DistanceEngine._learnAxisFrom`), and without a
//     learned axis the refinement is switched off before it starts.
//   * The DARK section genuinely slows down and speeds back up, staying inside
//     §12.2's ±25 % band around v₀ so the refinement is allowed to track it.
//
// Why it matters: coasting at v₀ = 25 m/s for the 80 s blackout would measure
// 2000 m against 1700 m of real travel — 17.6 % over, versus §19's 3 % target.
// A constant-speed fixture can never show that. This one can.
//
// Speed profile (piecewise-constant acceleration, integrated in closed form so
// the ground truth is exact by construction, like every other fixture here):
//
//   0–30 s   GPS on    15 → 25 m/s   a = +1/3     600 m
//   30–50 s  DARK      25 → 20 m/s   a = -0.25    450 m
//   50–90 s  DARK      20 m/s        a =  0       800 m
//   90–110 s DARK      20 → 25 m/s   a = +0.25    450 m
//   110–140s GPS on    25 m/s        a =  0       750 m
//                                    GROUND TRUTH 3050 m, dark leg 1700 m
void tunnelVarying() {
  // (durationS, startV, accel) — accel is exact, v is derived by integration.
  const segments = <List<double>>[
    [30, 15.0, 1.0 / 3.0], // approach, GPS on — trains the axis
    [20, 25.0, -0.25], // dark: slowing
    [40, 20.0, 0.0], // dark: steady
    [20, 20.0, 0.25], // dark: speeding back up
    [30, 25.0, 0.0], // exit, GPS on
  ];
  const darkFromS = 30;
  const darkToS = 110;

  final lines = <String>[];

  // Absolute distance and speed at time t, integrated exactly.
  double distanceAt(double t) {
    var d = 0.0;
    var elapsed = 0.0;
    for (final seg in segments) {
      final dur = seg[0], v0 = seg[1], a = seg[2];
      if (t <= elapsed) break;
      final dt = math.min(t - elapsed, dur);
      d += v0 * dt + 0.5 * a * dt * dt;
      elapsed += dur;
    }
    return d;
  }

  double speedAt(double t) {
    var elapsed = 0.0;
    for (final seg in segments) {
      final dur = seg[0], v0 = seg[1], a = seg[2];
      if (t < elapsed + dur) return v0 + a * (t - elapsed);
      elapsed += dur;
    }
    return segments.last[1];
  }

  double accelAt(double t) {
    var elapsed = 0.0;
    for (final seg in segments) {
      final dur = seg[0], a = seg[2];
      if (t < elapsed + dur) return a;
      elapsed += dur;
    }
    return 0.0;
  }

  final totalS = segments.fold<double>(0, (sum, s) => sum + s[0]);

  // GPS at 1 Hz, but nothing at all through the blackout.
  for (var s = 0; s <= totalS; s++) {
    if (s > darkFromS && s < darkToS) continue;
    lines.add(gps(
      ms: s * 1000,
      lat: kStartLat + distanceAt(s.toDouble()) * kDegPerMetre,
      lon: kStartLon,
      speed: speedAt(s.toDouble()),
      speedAcc: 0.5,
      heading: 0.0,
      accuracy: 5.0,
    ));
  }

  // Motion at 20 Hz throughout, carrying the REAL longitudinal acceleration.
  for (var ms = 0; ms <= totalS * 1000; ms += 50) {
    lines.add(motion(ms: ms, ax: accelAt(ms / 1000.0)));
  }

  lines.sort((a, b) {
    int msOf(String l) =>
        int.parse(RegExp(r'"ms":(\d+)').firstMatch(l)!.group(1)!);
    return msOf(a).compareTo(msOf(b));
  });

  final truth = distanceAt(totalS);
  final dark = distanceAt(darkToS.toDouble()) - distanceAt(darkFromS.toDouble());
  write(
      'tunnel_varying.jsonl',
      lines,
      'tunnel_varying · varying-speed approach (trains the axis) + 80 s dark '
          'with real acceleration · GROUND TRUTH ${truth.toStringAsFixed(1)}, '
          'dark leg ${dark.toStringAsFixed(1)} · coasting at v0 would give 2000.0');
}

void main() {
  cleanDrive();
  parked();
  tunnel();
  tunnelVarying();
  stdout.writeln('\ndegPerMetre = $kDegPerMetre  (R = $kEarthRadiusM m)');
}
