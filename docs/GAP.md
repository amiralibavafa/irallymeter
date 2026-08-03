# GAP — SPEC-v2 vs the code as it stands

Analysed against `main` @ `c151ca2`, on branch `SA-V1`. Phase 1: **no code changed.**
Every claim below is anchored to `file:line` in this repository.

## Headline

The architecture already matches SPEC-v2. **Section 17 is satisfied today** — the
Distance Engine is pure Dart, imports no plugins, and every method takes `now`
explicitly, so the whole state machine is deterministically replayable
(`lib/features/distance/domain/distance_engine.dart:41-43`). The five deltas are
**threshold and surface corrections, not a rewrite.** The one true "not implemented" is
the §5.1 measurement-state indicator on the digits.

Blast radius is concentrated: nine of the fixes land in
`lib/core/constants/app_constants.dart`, which is exactly what that file exists for.

---

## D1 — Speed from GNSS Doppler (§7)

**Spec:** primary source `Position.speed`; treat invalid if negative, null, **or
`speedAccuracy` worse than 2 m/s**; fall back to position differentiation only then;
display 0 below **1.5 m/s**.

| | |
|---|---|
| Status | **PARTIAL** |
| Blast radius | **Medium** — needs a new field on the GPS data model, so it touches the model, the mapper, the engine and the fixtures |

- ✅ `Position.speed` is already the primary source —
  `lib/features/gps/data/geolocator_gps_service.dart:99`
  (`speedMps: p.speed.isFinite && p.speed >= 0 ? p.speed : 0`).
- ✅ A differentiation fallback already exists, but in the *distance source*, not the
  GPS service — `lib/features/distance/domain/gps_distance_source.dart:98`
  (`speedMps: s.speedMps.isFinite && s.speedMps >= 0 ? s.speedMps : impliedSpeed`).
- ❌ **`speedAccuracy` is never read. Zero occurrences in `lib/`.** `GpsSample`
  (`lib/features/gps/domain/gps_sample.dart`) has no field for it, so the >2 m/s
  invalidation rule cannot currently be expressed at all. **This is the substantive
  part of D1.**
- ❌ An invalid Doppler speed becomes **`0`** at the service boundary
  (`geolocator_gps_service.dart:99`) rather than being marked invalid. By the time
  `GpsDistanceSource` sees it, `0` is indistinguishable from a genuine standstill, so the
  `impliedSpeed` fallback on line 98 **can never fire for a null/negative Doppler** — the
  only path that reaches it is a non-finite value. The fallback is effectively dead code
  for its stated purpose.
- ⚠️ Display floor is `speedNoiseFloorMps = 0.4` m/s (`app_constants.dart:24`), spec
  §7.1 says **1.5 m/s**.

## D2 — Speed-hold dead reckoning (§12)

**Spec:** freeze last valid `v₀`, accumulate `v₀ × Δt`; accelerometer may adjust **speed
only**, single integration, **clamped to ±25 % of v₀**; never double-integrate to
displacement.

| | |
|---|---|
| Status | **PARTIAL — the hard part is already right** |
| Blast radius | **Low** — one clamp expression |

- ✅ The model is **already** single-integration speed-hold anchored to GPS entry speed,
  and `lib/features/distance/domain/sensor_distance_source.dart:8-25` documents the
  rejection of double integration in the same terms the spec uses. The §12.1 error-growth
  argument was independently reached by the author.
- ✅ Never double-integrated to displacement; distance is `speed × dt`.
- ✅ Gravity/cornering removal and sign resolution via the learned forward axis
  (`longitudinal_axis_estimator.dart`), coasting at `v₀` when axis confidence is below
  `minAxisConfidence` (`app_constants.dart:95`) — this is §12.2's "disable the refinement
  if orientation is unstable", implemented as a confidence gate.
- ❌ **Clamp is wrong.** `sensor_distance_source.dart:76` sets
  `_speedCap = math.max(v * 1.5, v + 8.0)` — i.e. **+50 %, or +8 m/s (+28.8 km/h) at low
  speed**, and it is a *ceiling only*, with no floor. Spec §12.2 requires the total
  adjustment clamped to **±25 % of v₀**, symmetric. At v₀ = 23.6 m/s (the §13 worked
  example) the current cap permits 35.4 m/s where spec permits 29.5 m/s.
- ❌ No §12.3 confidence decay tiers (0–60 s / 60–180 s / >180 s). `tunnelSince` is
  tracked (`distance_engine_state.dart:34`) so the data is there, unused.

## D3 — Automatic detection, manual buttons removed (§15)

**Spec:** manual Tunnel Start/End **removed**; entry on >3 s without update, accuracy
worse than 50 m, invalid speed with degrading accuracy, or a >3× position jump; exit on
**3 consecutive fixes ≤20 m and mutually consistent**; debounced; §15.3 automatic
section logging.

| | |
|---|---|
| Status | **CONTRADICTS** |
| Blast radius | **High** — the manual path is woven through engine, providers, widgets and 2 test files |

- ✅ Automatic detection already exists and is well built: `_maybeEnterTunnel` /
  `_maybeExitTunnel` driven by a `tick` heartbeat, with the correct insight that a
  detector which only runs on incoming samples can never notice samples *stopping*
  (`distance_engine.dart:25-31`).
- ❌ **Manual override is still present and still outranks the detector.**
  `DistanceEngine.setManualTunnel` (`distance_engine.dart:167`), the `_manualTunnel`
  field (`:71`), `manualTunnel` on the state (`distance_engine_state.dart:24`),
  `lib/features/tunnel/presentation/widgets/tunnel_controls.dart` (7.4 KB of UI),
  `tunnel_providers.dart`, `tunnel_marker.dart`, and the `TUNNEL REC` status branch
  (`gps_status_bar.dart:94-96`).
- ❌ **Entry thresholds differ.** Only one condition is implemented: no healthy fix for
  `tunnelConfirmDelay = 2 s` (`app_constants.dart:66`) — spec says **3 s**. The
  accuracy-worse-than-50 m, invalid-speed-with-degrading-accuracy, and >3×-jump
  conditions are **not implemented**. Health currently collapses to
  `usableAccuracyMeters = 25` (`gps_distance_source.dart:44-47`).
- ❌ **Exit criterion is the wrong kind.** `_maybeExitTunnel` waits
  `tunnelExitConfirmDelay = 1500 ms` of health — a **duration**, where spec §15.2
  requires **three consecutive fixes ≤20 m that are mutually consistent**. With
  `gpsInterval = 200 ms` (`app_constants.dart:16`) requesting up to 5 Hz, 1500 ms could
  be 7 fixes or, on a 1 Hz chip, 1. The count guarantee the spec asks for does not exist.
- ❌ No §15.3 automatic section log (start/end/duration/estimated distance/held
  speed/correction applied). `tunnel_marker.dart` models a *manual* marker only.

## D4 — Invisible correction, visible estimated state (§16, §5.1)

**Spec:** blend over **15 s**, **60 s if >200 m** and flag it in the trip log; counters
never run backwards. Separately: **digits amber + "EST" badge + confidence decay** — hide
the correction, never hide the estimation.

| | |
|---|---|
| Status | **§16.1 PARTIAL · §16.2/§5.1 NOT IMPLEMENTED** |
| Blast radius | **Low** for the constants; **Medium** for the indicator (touches every numeric widget) |

- ✅ **Never backwards** is guaranteed twice over: the reconciler only ever *adds*
  (`distance_reconciler.dart:19-20`), and overshoot is deliberately not corrected because
  the entry→exit chord is a lower bound on road distance
  (`distance_engine.dart:246-258`). That asymmetry is correct and better-argued than the
  spec text.
- ✅ A rate ceiling makes "no visible jump" a guarantee rather than a hope
  (`distance_reconciler.dart:46`, `maxReconcileRateMps = 3.0`).
- ❌ **Window is 5 s, spec says 15 s** — `reconcileWindow` (`app_constants.dart:104`).
- ❌ **No >200 m → 60 s tier**, and no trip-log flag for that event.
- ⚠️ Interaction worth noting: with a 3.0 m/s ceiling, the §13 worked example's 56 m
  residual takes ~19 s to pay out regardless of the window setting. The rate cap, not the
  window, is the binding constraint for small residuals — so changing 5 → 15 s alone does
  not by itself make behaviour match §19's "complete ≤ 15 s". **These two constants have
  to be chosen together.**
- ⚠️ Status-bar-level state **does** exist: `TUNNEL · EST <dist>` in
  `AppColors.warn` and `GPS SYNC` in `AppColors.info`
  (`gps_status_bar.dart:97-103`). Good, but it is not what §5.1 asks for.
- ❌ **The digits never change.** `SpeedDisplay` colours with `colors.primary`
  unconditionally (`speed_display.dart:41`); `TripPanel` likewise
  (`trip_panel.dart:40,71`). Across `lib/features/dashboard/` and
  `lib/features/trip/presentation/`, `tunnelMode` is referenced in **exactly one file**
  (the status bar). **No amber digits, no EST badge, no RECONCILING/SYNC state on the
  values, no LOW CONFIDENCE tier.**

## D5 — Dart-only platform configuration (§18)

**Spec:** no custom Kotlin/Swift; Android `foregroundNotificationConfig` + 1 s interval;
iOS `activityType: automotiveNavigation`, `bestForNavigation`,
`allowBackgroundLocationUpdates: true`, `pauseLocationUpdatesAutomatically: false`,
`showBackgroundLocationIndicator: true`; plist and manifest entries.

| | |
|---|---|
| Status | **PARTIAL** |
| Blast radius | **Low** — one method, plus a platform import |

- ✅ **§18.3 is already fully satisfied.** `ios/Runner/Info.plist` carries all three
  usage strings and `UIBackgroundModes: location`. `android/app/src/main/AndroidManifest.xml`
  carries `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`,
  `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `WAKE_LOCK` and
  `POST_NOTIFICATIONS`, with a comment correctly explaining that missing
  `POST_NOTIFICATIONS` silently kills the position stream on Android 13+.
- ✅ No custom Kotlin/Swift beyond the default Flutter templates (127 bytes Kotlin,
  2.5 KB Swift = generated `AppDelegate`/`MainActivity`).
- ✅ `foregroundNotificationConfig` present, with a foreground-only fallback when the
  service is refused (`geolocator_gps_service.dart:37-45, 68-84`).
- ❌ **There is no `AppleSettings` branch at all.** `_settings()`
  (`geolocator_gps_service.dart:33-46`) returns `AndroidSettings` unconditionally, on
  every platform. It compiles because `AndroidSettings extends LocationSettings`, so this
  fails silently: on iOS **every one of the five §18.2 Apple options is unset**. Notably
  `pauseLocationUpdatesAutomatically` then defaults to iOS's own behaviour, which is
  exactly the "iOS will pause updates when it thinks the vehicle has stopped" failure the
  spec calls out.
- ❌ **`forceLocationManager: false`** (`geolocator_gps_service.dart:39`) — see below.
- ⚠️ §18.4 battery-optimisation prompt: not implemented. Spec frames it as a required
  user-facing prompt.

---

## Findings outside D1–D5

### F1 — Android routes through Play Services fused location (high impact)

`geolocator_gps_service.dart:39` sets `forceLocationManager: false`, so Android uses the
Google Play Services **FusedLocationProvider**. Two independent problems:

1. **§18.2 says it is wrong for this product:** "Fused location applies its own smoothing
   and road snapping, which is helpful for navigation and wrong for measurement." A rally
   meter that trusts road-snapped positions is measuring the map, not the car.
2. **It is a hard dependency on Google Play Services**, which carries directly into the
   Iran deployment question (Phase 2).

Spec §18.2 asks for this to be *evaluated during testing*, not assumed. Currently it is
assumed, in the direction the spec warns against.

### F2 — §6.1 noise gating is not implemented as specified

Spec §6.1 lists four rules. Current behaviour:

| §6.1 rule | Current | Status |
|---|---|---|
| Reject fix if accuracy > **30 m** | rejects > 25 m (`usableAccuracyMeters`) | ✅ stricter |
| Ignore displacement if speed < **1.5 m/s** | **no speed gate on distance at all** | ❌ |
| Ignore displacement **smaller than the fix's own accuracy** | fixed **1.0 m** floor, accuracy-independent (`gps_distance_source.dart:92`) | ❌ |
| Reject fix implying speed inconsistent with previous (**>3×**) | absolute 90 m/s teleport guard only (`:83`) | ❌ partial |

The third is the important one. A 20 m-accuracy fix can wander ~5 m while parked; a fixed
1.0 m floor accepts that as movement. The §19 target is **0.000 km over 10 minutes
parked**, and today's gating is not obviously sufficient to hold it. `SCENARIO · edge
cases 15` covers *stopped in a tunnel*, not parked under a degraded open-sky fix — so the
existing suite does not currently prove this target.

### F3 — `gpsInterval = 200 ms` requests 5 Hz, spec baselines 1 Hz

`app_constants.dart:16`. Exceeds the §19 "≥ 1 Hz sustained" target, so not a failure — but
§18.2 explicitly specifies `intervalDuration` of **1 second**, and 5 Hz has direct battery
and thermal cost on a windscreen-mounted phone (Phase 4). Worth a deliberate decision
rather than drift.

### F4 — Pre-existing skipped test is a real UI defect

`test/dashboard_layout_test.dart:85` — portrait overflows the top bar by ~142 px, skipped
with a documented rationale. Recorded in `BASELINE.md`. Not Phase 3 scope; it is a Phase 4
input because it collides head-on with the 44×44 pt touch-target requirement.

---

## Are the §19 targets testable against this architecture?

**Yes — the architecture is ready, the harness is not.**

| §19 target | Testable today? |
|---|---|
| Trip distance ≤1.0 % over 50 km | ✅ engine is pure Dart and replayable — **but no fixture exists** |
| 0.000 km over 10 min parked | ✅ mechanically — see F2, likely to **fail** at current gating |
| Speed ±2 km/h, latency ≤1.0 s | ⚠️ EMA is in `gps_state.dart:69`; latency is not asserted anywhere |
| Estimation ≤3 % over a 2 km gap | ✅ `tunnel_system_test.dart` covers the machine; **no accuracy assertion against a ground truth** |
| Recovery: no visible jump, ≤15 s | ⚠️ monotonicity is provable; the **≤15 s bound cannot currently be met** — see the D4 rate-cap note |
| ≥1 Hz sustained, foreground and background | ❌ **not unit-testable** — needs a device |

The single missing piece is §20.1: there is no recorder, no replay driver, and no fixture
with known ground truth. That is Phase 3.0 and it correctly comes before any behaviour
change.

---

## Ordering consequence for Phase 3

Two couplings the plan's step order must respect:

1. **D1 before F2.** The §6.1 speed gate needs a *valid* speed to gate on, and validity is
   what D1 introduces. Gating on today's coerced `0` would suppress real movement.
2. **D4's two constants move together.** `reconcileWindow` and `maxReconcileRateMps` both
   bind; changing only the window will not satisfy §19.
