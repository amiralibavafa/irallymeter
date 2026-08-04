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

void main() {
  cleanDrive();
  parked();
  tunnel();
  stdout.writeln('\ndegPerMetre = $kDegPerMetre  (R = $kEarthRadiusM m)');
}
