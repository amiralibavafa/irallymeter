# PHASE 3 — COMPLETENESS VERIFICATION

Phase 3 checked against **SPEC-v2 itself**, section by section, rather than
against `GAP.md` or my own commit notes. Written after the implementation work,
specifically to find what those two missed.

**It found two real misses.** One is fixed (`[3.7]`); one needs a decision.

State at time of writing: branch `SA-V1` at `9e79972`, **200 pass / 2 skip /
0 fail**, `flutter analyze` 2 pre-existing issues.

---

## The two things this audit caught

### ✅ FIXED — §19 row 3 was never tested, and it was failing

"All six §19 targets pass" was counting the wrong six. `replay_targets_test.dart`
has `T1`–`T6`, but **`T6` is a bonus full-trace check, not a §19 row**. Lining the
tests up against the actual §19 table showed row 3 had no test at all:

| §19 row | Target | Test |
|---|---|---|
| 1 | Trip distance, 50 km → ≤ 1.0 % | `T1` ✅ |
| 2 | Parked 10 min → 0.000 km | `T2` ✅ |
| **3** | **Displayed speed ±2 km/h, latency ≤ 1.0 s** | **was NOT TESTED** |
| 4 | Estimation Mode, 2 km → ≤ 3 % | `T3` ✅ |
| 5 | Recovery: no visible jump, ≤ 15 s | `T4` + `T5` ✅ |
| 6 | ≥ 1 Hz sustained, foreground and background | platform property — see below |

And it was failing. Measured on the pre-`[3.7]` filter:

```
1 Hz: settled after 8 samples = 8.00 s   (budget 1.0 s)
5 Hz: settled after 8 samples = 1.60 s   (budget 1.0 s)
```

Missed at **both** rates, worst at 1 Hz — which is the rate §19 row 6 baselines
and the rate Amirali's own comment on `gpsInterval` says most Android chips
deliver. The cause was that the EMA weight was **per sample**, so the filter's lag
in seconds was a property of the chip rather than of the clock.

Fixed in `[3.7]`: `α = 1 − e^(−Δt/τ)`, `τ = 250 ms`, timestamp threaded through
from `gps_providers`. Five new tests (`T7`–`T7e`), including one asserting that a
5× change in fix rate no longer changes the settling time.

### ⏸ NOT DONE — §8 asks for two averages and a label; there is one average and no label

> "The application should track both moving average (excluding stops) and overall
> average (including stops), and **make clear which one is displayed**."

`AverageSpeedCalculator` implements the **overall** average only —
`_elapsed += d.dt` accrues on every accepted delta, including while stationary,
which its own doc comment describes correctly. There is no moving average, and
the dashboard tile is labelled simply `AVG SPEED`, which does not say which of
the two it is.

**Not fixed, deliberately.** Adding the second accumulator is ten lines of pure
Dart, but *which one the dashboard shows by default, and how it is labelled in a
tile that is already tight*, is a design decision on a driving instrument. That
belongs to Amirali, not to me, and it is the sort of thing this audit is supposed
to surface rather than quietly invent. See the question at the end.

---

## Every spec section, verified

| § | Requirement | Status | Evidence |
|---|---|---|---|
| 5 | Main dashboard: speed, Trip 1/2, ODO, average | ✅ | Live on device, `/tmp/shots/17` |
| **5.1** | **Measurement state indicator** | ✅ `[3.5]` | `measurement_status.dart`, `measurement_badge.dart`; amber digits + `EST`/`EST?`/`SYNC` on speed, Trip A/B, ODO **and** AVG |
| 6 | Distance from consecutive fixes | ✅ pre-existing | `gps_distance_source.dart` |
| **6.1** | **Noise gating, 4 rules** | ✅ `[3.2]` + `[3.4d]` | rule 1 accuracy (25 m, stricter than the spec's 30); rule 2 ≥1.5 m/s; rule 3 floor = **the fix's own accuracy**, not a fixed 1 m (that was the whole 2 555 m parked-drift bug); rule 4 reject >3× predicted displacement |
| **7.1** | **Speed from Doppler, fallback on bad `speedAccuracy`** | ✅ `[3.1]` | `hasValidDopplerSpeed`; the service no longer coerces bad Doppler to `0`, which had left the fallback dead code |
| **7.2** | **Display smoothing, ≤ ~1 s latency** | ✅ `[3.7]` | Was 8.00 s at 1 Hz. Now time-based. `speed_display_latency_test.dart` |
| 8 | Average speed | ⏸ **PARTIAL** | Overall average only; no moving average; tile does not say which. **See above** |
| 9 | Trip 1 / Trip 2, independent | ✅ pre-existing | Independent resets, verified live |
| 10 | Map: location, driven path | ✅ / ⚠️ | Renders; **offline is unimplemented and the planned route is prohibited** — `IRAN-CONSTRAINTS.md` §4 |
| 11 | GNSS limitations | ✅ n/a | Narrative |
| **12.1** | **Speed-hold dead reckoning** | ✅ pre-existing | Model was already right — single integration, explicit comment rejecting double integration |
| **12.2** | **Accelerometer refines SPEED only, ±25 % of v₀** | ✅ `[3.3]` | Was `max(v×1.5, v+8)`. **Two judgement calls open — see below** |
| **12.3** | **Confidence decay** | ✅ `[3.5]` | 60 s → reduced, 180 s → low; badge **text** changes, not just colour |
| 13 | Estimation example | ✅ n/a | Narrative |
| **14** | **Manual correction removed from priority list** | ✅ `[3.4b]` | `lib/features/tunnel/` **deleted**; no override anywhere |
| **15.1** | **Automatic entry** | ✅ `[3.4a]` | 3 s silence **or** a fix worse than 50 m, entering at once |
| **15.2** | **Automatic exit, debounced** | ✅ `[3.4a]` | **Three consecutive fixes ≤20 m, mutually consistent** — a count, not a timer. A duration accepted 7 fixes at 5 Hz and 1 at 1 Hz |
| **15.3** | **Automatic section logging** | ✅ `[3.4c]` engine · ⏸ no UI | `estimated_section.dart`. The data exists; §15.3's "gives the user the same information the manual buttons would have provided" has no screen — `PHASE4-AUDIT.md` P11 |
| **16.1** | **Invisible correction, 15 s / 60 s / never backwards** | ✅ `[3.5]` | Window 5 s → 15 s; >200 m pays out over 60 s; rate cap re-derived from the spec so it never binds on a compliant correction |
| **16.2** | **Estimated state visible** | ✅ `[3.5]` | See §5.1 |
| 17 | Engine pure Dart, headless-testable | ✅ **already satisfied** | Was true before this audit — the prompt assumed otherwise |
| 18.1 | Plugin list | ✅ | All present |
| **18.2** | **Platform settings in Dart** | ✅ `[3.6]` | Was `AndroidSettings` on **every** platform — compiled via inheritance, failed silently. Now branches on `defaultTargetPlatform`; all five Apple options set; `forceLocationManager: true` |
| 18.3 | Info.plist / Manifest | ✅ **already correct** | Untouched, as instructed |
| 18.4 | OEM background killing | ✅ n/a | Explicitly unsolvable in code |
| 19 | Accuracy targets | ✅ rows 1–5 · ⚠️ row 6 | See the table above |
| **20.1** | **Record and replay** | ✅ `[3.0]` · ⏸ bonus | Recorder, headless player, 3 fixtures. **The optional debug-menu fixture player was never built** |
| 20.2 | Ground truth | ❌ **NOT DONE** | **No road test has happened.** See below |
| 20.3 | Test list | ✅ mostly | 200 tests. Gaps: background/screen-off over a long drive, Android battery-optimisation survival, iOS background pausing, permissions flow on iOS — all device work |

---

## What is NOT done, stated plainly

1. **§20.2 ground truth — no road test.** Every accuracy number in this audit
   comes from fixtures generated by `tool/generate_fixtures.dart`, where ground
   truth is exact by construction, or from an emulator. §20.2 asks for a measured
   route, a route with real tunnels, and a tight curved road. **None of it has
   happened.** The §19 targets are met *in replay*; nobody may claim they are met
   in the field.
2. **The tunnel feature has never met a real tunnel.** `tunnel_2km.jsonl` feeds
   **zero accelerometer input**, so only the coast-at-v₀ path is exercised —
   §12.2's ±25 % refinement has never run inside a full tunnel replay, only in
   isolated unit tests. GPS was genuinely cut on device once
   (`adb shell settings put secure location_mode 0`) and the EST badges appeared
   correctly, but that is not a drive.
3. **§19 row 6 (≥ 1 Hz sustained, foreground and background) is unverified.** It is
   a runtime property of the device and the OS, not something a unit test can
   assert. It needs a long screen-off run on real hardware — which is also §20.3's
   "background operation on both platforms" line.
4. **§8's moving average and its label.** Above.
5. **§20.1's optional debug-menu fixture player.** The harness is headless-only;
   there is no way to watch a fixture play into the running app. Listed as a bonus
   in the original brief and never built.
6. **No iOS runtime testing.** The project builds for the simulator; nobody has
   run it there.

---

## The two §12.2 judgement calls still waiting on Amirali

Both are deviations from a literal reading of §12.2, flagged in the code and in
the commit messages. **Neither blocks anything.**

1. **Saturate, not snap back.** §12.2 says "clamp … if the correction wants to
   exceed this, ignore it and hold v₀". Implemented as **saturating at the
   ceiling**. The literal snap-back was built first and **sawtooths** — climbs to
   25, drops to 20, climbs again, settles at 22 — which on a driver-facing readout
   looks like a fault.
2. **Applied upwards only.** The ±25 % bound is applied only upwards, so
   deceleration runs to a full stop. Symmetric would hold a car braking to a halt
   at v₀ and invent distance, and `tunnel_system_test` 11 already asserts "must
   settle at a clean stop". The risk is asymmetric: an **over-estimate is
   permanent** (the engine reconciles undershoot only), an under-estimate recovers
   on the next fix.

---

## Question for Amirali, on §8

The spec asks for both a moving average and an overall average, and to make clear
which is displayed. Today there is one average (overall) and one unlabelled tile.
The engine change is small; the display decision is not. Which does a rally crew
actually want on the cluster — the overall average, the moving average, both, or
one with a way to switch?
