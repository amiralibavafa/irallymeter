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

// ---------------------------------------------------------------------------
// 5. mountain_hairpins — SPEC-v2 §19's "note on curved roads"
// ---------------------------------------------------------------------------
//
// "At a 1 Hz update rate, the application measures straight lines between
// fixes. On tight mountain or gravel roads these straight lines cut across
// curves, so measured distance will read slightly short."
//
// This fixture MEASURES that effect instead of leaving it as a warning. The car
// drives 20 semicircular hairpins of radius 30 m at 12 m/s (43 km/h), sampled
// at 1 Hz. Ground truth is the ARC length the car actually drove; the engine
// can only ever see the chords between fixes.
//
// The gap is a property of geometry, not a defect — which is why §19 defers a
// calibration factor rather than calling it a bug. The test asserts the
// direction (short, never long) and pins the magnitude so a regression that
// made it worse would be visible.
void mountainHairpins() {
  const radiusM = 30.0;
  const v = 12.0;
  const turns = 20;
  final lines = <String>[];

  // Arc length of a semicircle, and how long it takes at v.
  const arcPerTurn = math.pi * radiusM;
  final secondsPerTurn = arcPerTurn / v;

  var t = 0.0;
  var groundTruth = 0.0;
  // Track the car in a local metric frame, then convert once.
  var northM = 0.0, eastM = 0.0;
  var bearing = 0.0; // radians, 0 = north

  final samples = <List<double>>[]; // t, northM, eastM, speed, headingDeg

  for (var turn = 0; turn < turns; turn++) {
    // Alternate left/right so the road snakes rather than spiralling away.
    final sign = turn.isEven ? 1.0 : -1.0;
    final steps = (secondsPerTurn * 10).round(); // integrate at 10 Hz
    final dt = secondsPerTurn / steps;
    for (var i = 0; i < steps; i++) {
      final dTheta = sign * (v * dt) / radiusM;
      bearing += dTheta;
      northM += v * dt * math.cos(bearing);
      eastM += v * dt * math.sin(bearing);
      groundTruth += v * dt;
      t += dt;
      samples.add([
        t,
        northM,
        eastM,
        v,
        (bearing * 180 / math.pi + 360) % 360,
      ]);
    }
  }

  // Emit at 1 Hz by picking the nearest integrated sample to each second.
  for (var s = 0; s <= t.floor(); s++) {
    final target = s.toDouble();
    var best = samples.first;
    for (final smp in samples) {
      if ((smp[0] - target).abs() < (best[0] - target).abs()) best = smp;
    }
    lines.add(gps(
      ms: s * 1000,
      lat: kStartLat + best[1] * kDegPerMetre,
      lon: kStartLon +
          best[2] * kDegPerMetre / math.cos(kStartLat * math.pi / 180.0),
      speed: best[3],
      speedAcc: 0.5,
      heading: best[4],
      accuracy: 5.0,
    ));
  }

  write(
      'mountain_hairpins.jsonl',
      lines,
      'mountain_hairpins · $turns semicircles r=${radiusM}m at ${v}m/s, 1 Hz · '
          'GROUND TRUTH ${groundTruth.toStringAsFixed(1)} (ARC length; chords '
          'between 1 Hz fixes must read SHORT — §19 note on curved roads)');
}

// ---------------------------------------------------------------------------
// 6. stop_start_traffic — §6.1 must not creep across many stops
// ---------------------------------------------------------------------------
//
// Twelve cycles of: accelerate to 14 m/s, hold, decelerate, then sit still for
// 25 s with ordinary standstill wander. A single 10-minute stop is already
// covered by parked_10min; this is the harder case — the gate has to re-arm
// correctly every time, twelve times, without leaking a few metres per stop.
// Five metres of creep per stop is 60 m over this trace and would be invisible
// in any single-stop test.
void stopStartTraffic() {
  final rng = Lcg(775533);
  final lines = <String>[];
  var ms = 0;
  var northM = 0.0;
  var groundTruth = 0.0;

  void fix(double n, double speed, double acc, {double? eastM}) {
    lines.add(gps(
      ms: ms,
      lat: kStartLat + n * kDegPerMetre,
      lon: kStartLon +
          (eastM ?? 0) * kDegPerMetre / math.cos(kStartLat * math.pi / 180.0),
      speed: speed,
      speedAcc: 0.5,
      heading: 0.0,
      accuracy: acc,
    ));
    ms += 1000;
  }

  for (var cycle = 0; cycle < 12; cycle++) {
    // Accelerate 0 -> 14 m/s over 7 s, cruise 10 s, decelerate over 7 s.
    for (var s = 1; s <= 7; s++) {
      final v = 14.0 * s / 7.0;
      northM += v;
      groundTruth += v;
      fix(northM, v, 5.0);
    }
    for (var s = 0; s < 10; s++) {
      northM += 14.0;
      groundTruth += 14.0;
      fix(northM, 14.0, 5.0);
    }
    for (var s = 6; s >= 0; s--) {
      final v = 14.0 * s / 7.0;
      northM += v;
      groundTruth += v;
      fix(northM, v, 5.0);
    }
    // Stopped at the lights: 25 s of wander, ±3 m, tiny reported speeds.
    for (var s = 0; s < 25; s++) {
      fix(northM + rng.symmetric() * 3.0, rng.symmetric().abs() * 0.5, 6.0,
          eastM: rng.symmetric() * 3.0);
    }
  }

  write(
      'stop_start_traffic.jsonl',
      lines,
      'stop_start_traffic · 12 x (accel/cruise/decel + 25 s stopped with ±3 m '
          'wander) · GROUND TRUTH ${groundTruth.toStringAsFixed(1)} — any creep '
          'per stop compounds 12x');
}

// ---------------------------------------------------------------------------
// 7. multi_tunnel — five short tunnels back to back
// ---------------------------------------------------------------------------
//
// A single long blackout is covered by tunnel_2km and tunnel_varying. A rally
// stage through a gorge is a string of SHORT ones, and that stresses different
// code: entry debounce, exit debounce, re-anchoring, and whether five
// reconciliations in a row stack up unpaid corrections. It is also the only
// fixture that produces more than one §15.3 section.
void multiTunnel() {
  const v = 22.0;
  final lines = <String>[];
  var s = 0;
  var metres = 0.0;
  var groundTruth = 0.0;
  final darkSpans = <List<int>>[];

  void clean(int seconds) {
    for (var i = 0; i < seconds; i++) {
      metres += v;
      groundTruth += v;
      lines.add(gps(
        ms: s * 1000,
        lat: kStartLat + metres * kDegPerMetre,
        lon: kStartLon,
        speed: v,
        speedAcc: 0.5,
        heading: 0.0,
        accuracy: 5.0,
      ));
      s++;
    }
  }

  void dark(int seconds) {
    darkSpans.add([s, s + seconds]);
    for (var i = 0; i < seconds; i++) {
      metres += v;
      groundTruth += v;
      s++;
    }
  }

  clean(20);
  for (var i = 0; i < 5; i++) {
    dark(25); // 550 m each
    clean(20); // 440 m of daylight between them
  }

  // Motion throughout, no net acceleration: constant speed through each tunnel.
  final totalMs = s * 1000;
  for (var t = 0; t <= totalMs; t += 50) {
    lines.add(motion(ms: t, ax: 0.0));
  }

  lines.sort((a, b) {
    int msOf(String l) =>
        int.parse(RegExp(r'"ms":(\d+)').firstMatch(l)!.group(1)!);
    return msOf(a).compareTo(msOf(b));
  });

  write(
      'multi_tunnel.jsonl',
      lines,
      'multi_tunnel · 5 x 25 s blackouts at ${v}m/s separated by 20 s clean · '
          'GROUND TRUTH ${groundTruth.toStringAsFixed(1)}, each dark leg 550.0');
}

// ---------------------------------------------------------------------------
// 8. urban_canyon — degraded but never absent
// ---------------------------------------------------------------------------
//
// The nastiest real case, and the one most likely to be wrong: fixes keep
// arriving at 1 Hz, so the silence trigger never fires, but their accuracy
// swings between 6 m and 45 m and the positions scatter accordingly.
//
// This sits deliberately across three thresholds — usableAccuracyMeters (25),
// estimationEntryAccuracyMeters (50) and the exit bar (20) — so it exercises
// the gap the engine is supposed to have: a fix too poor to integrate but not
// poor enough to abandon GPS over. The car really does travel 18 m/s the whole
// time, so any answer far from ground truth means the gating is wrong in one
// direction or the other.
void urbanCanyon() {
  final rng = Lcg(31415926);
  const v = 18.0;
  final lines = <String>[];
  var metres = 0.0;

  for (var s = 0; s <= 300; s++) {
    metres = v * s;
    // Accuracy breathes between 6 m and 45 m on a slow cycle.
    final acc = 6.0 + 39.0 * (0.5 + 0.5 * math.sin(s / 11.0));
    // Scatter proportional to the reported accuracy — a well-behaved receiver.
    final scatter = rng.symmetric() * acc * 0.5;
    lines.add(gps(
      ms: s * 1000,
      lat: kStartLat + (metres + scatter) * kDegPerMetre,
      lon: kStartLon +
          rng.symmetric() *
              acc *
              0.5 *
              kDegPerMetre /
              math.cos(kStartLat * math.pi / 180.0),
      speed: v,
      speedAcc: 0.8,
      heading: 0.0,
      accuracy: acc,
    ));
  }

  // Motion throughout. Without it this fixture would be unfair: the engine
  // drops into Estimation Mode when the accuracy breathes past the integrable
  // limit, and with no inertial input there is nothing for it to estimate FROM,
  // so it would measure nothing and the fixture would be blaming the engine for
  // data it was never given. A real phone always has an accelerometer.
  for (var t = 0; t <= 300 * 1000; t += 50) {
    lines.add(motion(ms: t, ax: 0.0));
  }

  lines.sort((a, b) {
    int msOf(String l) =>
        int.parse(RegExp(r'"ms":(\d+)').firstMatch(l)!.group(1)!);
    return msOf(a).compareTo(msOf(b));
  });

  write(
      'urban_canyon.jsonl',
      lines,
      'urban_canyon · 300 s at ${v}m/s, accuracy breathing 6-45 m with '
          'proportional scatter · GROUND TRUTH ${(v * 300).toStringAsFixed(1)}');
}

// ---------------------------------------------------------------------------
// 9. long_drive_500km — float accumulation over a real rally distance
// ---------------------------------------------------------------------------
//
// The prompt's Phase 5 adversarial brief names "float accumulation drift over a
// 500 km trip". 20 000 fixes at 25 m each. Every increment is identical, so any
// error is purely the accumulator's, and the expected total is exact.
void longDrive() {
  const stepM = 25.0;
  const steps = 20000; // 500.000 km
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
  write('long_drive_500km.jsonl', lines,
      'long_drive_500km · 500000.000 m due north · 25 m/s · 1 Hz · GROUND TRUTH 500000.0');
}

void main() {
  cleanDrive();
  parked();
  tunnel();
  tunnelVarying();
  mountainHairpins();
  stopStartTraffic();
  multiTunnel();
  urbanCanyon();
  longDrive();
  stdout.writeln('\ndegPerMetre = $kDegPerMetre  (R = $kEarthRadiusM m)');
}
