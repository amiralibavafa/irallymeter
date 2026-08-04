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

### F1 — Android routes through Play Services fused location (medium impact)

`geolocator_gps_service.dart:39` sets `forceLocationManager: false`, so Android prefers the
Google Play Services **FusedLocationProvider**.

**Corrected 2026-08-03 after testing it live.** The original draft of this finding claimed
this was a hard break on Play-Services-less devices. **That is wrong.** Running the app on
the `rally_aosp` emulator (AOSP `default` system image, no Play Services) produced:

```
W/GooglePlayServicesUtil: com.irallyclub.irallymeter requires the Google Play Store,
                          but it is missing.
```

…and then GPS worked anyway — `GPS ±5m` green, distance accumulating normally. geolocator
falls back to the platform `LocationManager` on its own. So the availability argument is a
warning, not a failure, and the finding is downgraded from high to medium.

**The reason to flip it stands, and it is the stronger one — §18.2's own words:** "Fused
location applies its own smoothing and road snapping, which is helpful for navigation and
wrong for measurement." A rally meter that trusts road-snapped positions is measuring the
map, not the car. §18.2 asks for this to be *evaluated during testing*; today it is
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

### F4 — The skipped test is a live, visible defect (confirmed on device)

`test/dashboard_layout_test.dart:85` — portrait overflows the top bar, skipped with a
documented rationale. Recorded in `BASELINE.md`.

**Confirmed live 2026-08-03**: at 1080×2400 (an ordinary phone), the running app renders a
yellow-and-black `OVERFLOWED BY 70 PIXELS` banner across the top bar — see
`/tmp/shots/04-after-restart.png` and `05-after-drive.png`. **This is not test debt; it
ships.** Not Phase 3 scope, but a Phase 4 input, because it collides head-on with the
44×44 pt touch-target requirement — the two constraints are precisely what conflict.

### F5 — A fresh install hangs on the Flutter splash screen (high impact, NEW)

Found by running the app, not by reading it. On first launch with no permissions yet
granted:

```
E/flutter: Unhandled Exception: PlatformException(PermissionHandler.PermissionManager,
  A request for permissions is already running, please wait for it to finish before
  doing another request ...)
```

The app issues overlapping permission requests; the second throws, the exception is
**unhandled**, and startup never completes — the app sits on the Flutter splash logo
indefinitely (`/tmp/shots/03-dashboard.png`). Hot-restarting with permissions pre-granted
boots straight to the dashboard (`04-after-restart.png`), which isolates the fault to the
**first-run path** — i.e. every real user's first launch.

Not one of D1–D5 and not in scope for Phase 3 as written, but it outranks most of the
backlog: a rally computer that has to be launched twice is not shippable.

### F6 — Both permission prompts appear cold (store-rejection risk, NEW)

The location prompt (`/tmp/shots/00-baseline.png`) and the notifications prompt
(`01-dashboard-first-fix.png`) are both raised with **no in-app rationale screen first**.
Google Play and the App Store both scrutinise background-location requests made without
prior context. `POST_NOTIFICATIONS` is also requested cold, and denying it is what
`AndroidManifest.xml`'s own comment warns will silently kill the position stream.

### F7 — RETRACTED. The screenshot showed correct behaviour.

**This finding was wrong and is withdrawn. Recorded rather than deleted, because the
reasoning error is worth keeping.**

The claim was that `/tmp/shots/05-after-drive.png` — `CURRENT SPEED 0 km/h` beside
`AVG SPEED 43 km/h`, `TRIP A/B 0.61 km`, `ODO 614 m` — proved the D1 dead fallback on the
instrument face.

It proved nothing of the sort. **The display has its own, working, position-differentiation
fallback** at `lib/features/gps/presentation/providers/gps_providers.dart:53-63`, with a
comment from the author naming this exact scenario: *"the Android emulator and some real GPS
chips never supply a speed value, so without this the readout would sit at 0 even while
moving."*

What actually happened: `adb emu geo fix` sets a **persistent** location, which the emulator
then re-reports at 1 Hz forever. Once the drive loop stopped, every subsequent fix carried
the *same* coordinates → zero displacement → derived speed 0 → the readout decayed to 0 and
stayed there. The 43 km/h average was historical, over the leg that had been driven. **The
vehicle had stopped. The instrument was correct.**

The error was reading a screenshot taken *after* the stimulus ended as though it were taken
during. A dashboard showing 0 for a stationary car is the whole point of §6.1.

**D1 remains a real gap** — see the D1 section — but the defect is narrower and lives
elsewhere: `speedAccuracy` is never consulted, and the *distance source's* fallback (as
opposed to the display's) was genuinely unreachable. Its consequence is not a cosmetic
readout but `DistanceDelta.speedMps`, which is what seeds the tunnel entry anchor — on a
Doppler-less device that anchor was `0`, so a car entering a tunnel would coast at a
standstill and measure nothing for the whole blackout. That is covered by
`test/speed_source_test.dart:10`.

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
