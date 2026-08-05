# AUDIT REPORT — iRallyMeter, SPEC-v2 audit and upgrade

Phases 0–5 (Claude's half). `origin/main` never touched.

| | |
|---|---|
| Base | `main` `c151ca2` — Amirali's initial commit, untouched throughout |
| Backend branch | `SA-V1` `c6f6257` — 34 commits (Phase 3) |
| UI + review branch | `SA-V2` `8a05172` — 48 commits (Phase 4, security, Phase 5 self-review) |
| PR | **Not opened yet** — waits on Codex findings, per Saam's decision |

---

## 0. Corrections to earlier claims in this repo

Recorded here rather than by rewriting history, because the commits below are
pushed and this branch does not rewrite pushed history.

**`914b75a` (`[SA-V2 18]`) opens with "It is needed, and that is not what he
was looking at."** The second half stands: the map was showing a REC light on a
cold launch with nothing recording, which is the defect that commit fixes. **The
first half was asserted without checking and is wrong.** `docs/SPEC-v2.md` line
297 lists "GPX route import, stage creation" under **possible future** map
features, so route recording is not a current spec requirement. Whether it
belongs in v1 is now question **B9** in `docs/QUESTIONS-FOR-AMIRALI.md`, and it
is Amirali's call, not ours. Nothing was removed.

## 1. Baseline vs final

| | Baseline (`c151ca2`) | Final (`8a05172`) |
|---|---|---|
| Tests passing | **115** | **313** |
| Failing | 0 | 0 |
| Skipped | 1 | 1 |
| `flutter analyze` | 2 issues | 2 issues (the same two) |
| Test files | 7 | 24 |
| Release APK | never built | **builds, installs, runs** (53.2 MB) |

The 2 analyzer issues are pre-existing and untouched: a deprecated `activeColor`
in `settings_screen.dart:333` and an unused test parameter in
`distance_speed_test.dart:263`.

**The one skipped test is deliberate and asserted at FULL STRENGTH.**
`road_scenarios_test` 12 — urban canyon reads **−12.50 %** (4724.7 m measured
against 5400.0 m) versus §19's 1 % target. It has never been weakened. Two
skips that existed during the work were closed by fixing the defect, not the
assertion: `dashboard_layout_test` 02 (portrait overflow) and 05 (which was
passing vacuously).

---

## 2. The five spec deltas

| | Requirement | Status | Where |
|---|---|---|---|
| **D1** | Speed from `Position.speed`, fall back to differentiation | DONE | `[3.1]` — `speedAccuracyMps` + `hasValidDopplerSpeed` added; an invalid Doppler no longer becomes `0` |
| **D2** | Speed-hold dead reckoning, ±25 % of v₀, never double-integrated | DONE | `[3.3]` — the model was already single-integration; the ceiling was `max(v·1.5, v+8)` and is now `v₀·1.25` |
| **D3** | Manual tunnel buttons removed, detection automatic | DONE | `[3.4a–c]` — `lib/features/tunnel/` deleted entirely, §15.1/15.2/15.3 implemented |
| **D4** | Invisible correction, visible estimated state | DONE | `[3.5]` — 15 s / 60 s / >200 m, plus `EST`/`EST?`/`SYNC` on all four readouts |
| **D5** | Dart-only platform config | DONE | `[3.6]` — **iOS had never been configured at all** (see §3) |

---

## 3. The defects that mattered, in order of severity

Each is stated with the number that proves it.

### 3.1 A faster GPS made the app measure LESS — `[3.16]`
§6.1 rule 3 re-anchored on rejection, so a displacement below the noise floor
was **destroyed rather than ignored**. The threshold is `accuracy × fixRate`, so
**at the 5 Hz the app itself requests, everything below 90 km/h was discarded.**
Hidden for fourteen steps because every fixture was 1 Hz at 20–25 m/s.
Fix: hold the anchor when the floor rejects. `stop_start` −5.04 % → **−0.12 %**;
parked drift stayed exactly 0.0.

### 3.2 Estimation Mode could never end, and invented distance while stuck — `[SA-V2 7]`
`isHealthy` accepts 25 m; §15.2 exits only at 20 m; nothing else ended the mode.
The 21–25 m band was a trap — good enough to measure with, not good enough to
escape with. A car slowing under a latch kept being counted at its entry speed:
**2400 m reported for 1200 m of ground truth**, and that over-read is permanent
because `_reconcileAgainst` pays out undershoot only.
Fix: a sustained run of usable, mutually consistent fixes also exits. Window
10 s, which bounds the invented distance to `(v₀ − actual) × 10 s`.

### 3.3 A tunnel is silence — `[3.14]` → `[3.15]`
The stream could never recover from a real OFF→ON toggle. The first fix was a
flat `.timeout()` and was **worse than the bug**: on device it restarted the
Android foreground service ~20 times inside one 400 s tunnel — the very service
keeping the app alive in there. Rebuilt so a teardown needs *evidence*, not
silence. Measured at **zero restarts** across 150 s and 90 s of silence.

### 3.4 iOS had never been configured — `[3.6]`
`_settings()` returned `AndroidSettings` on **every** platform. It compiled and
ran because `AndroidSettings` *is* a `LocationSettings` and the iOS plugin reads
recognised fields off the base class, so the failure was **silent**. iOS got
default accuracy, no `activityType`, and `pauseLocationUpdatesAutomatically` at
its default — which pauses updates when iOS thinks the vehicle stopped, i.e. at
every start line and time control.

### 3.5 A trip reset leaked the previous leg — `[3.17]`
Up to **715 m** of the old leg's tunnel correction drip-fed into the new one.
Reset now settles the reconciler first.

### 3.6 The compass, three separate causes — `[3.11]`, `[SA-V2 2]`
Reported from the road as "laggy, has a delay and isn't accurate". All three
fixed: a per-sample EMA made lag a property of the handset's sensor rate; "Use
true north" changed only a **label** with no declination ever applied; and tilt
compensation derived "down" from the raw accelerometer, so it followed braking
and cornering. **The per-sample-filter bug class appeared three times** — speed
display, compass needle, compass tilt.

### 3.7 The app could never start — `[SA-V2 1]`
`main()` awaited two permission requests before `runApp` with no try/catch. They
raced on first run and threw, so `runApp` was never reached and the app hung on
the Flutter splash forever.

### 3.8 One transient GPS error killed background tracking — `[SA-V2 8]`
The reconnect loop dropped the foreground service on any error and never
restored it, silently downgrading the app for the rest of the drive. Now needs
two consecutive failures; any delivered fix resets the count.

### 3.9 Portrait overflowed by 142 px — `[SA-V2 4]`
Amirali's own skipped test recorded that exact number, and it **grew with the
status text** — 137 px in Estimation Mode, i.e. worst when the co-driver most
needs to read it. Portrait now stacks the nav row. Nothing was shrunk; the
glove-sized targets ended up further apart.

### 3.10 Permissions arrived cold — `[SA-V2 5]`
No rationale before the system dialogs. Also `main()` re-prompted, cold, only
the user who had already said no — an already-granted permission makes
`ensurePermission()` a silent no-op, so that call helped nobody and hurt exactly
one person.

---

## 4. Security review

`docs/SECURITY-REVIEW.md`. No telemetry, no analytics SDK, no crash reporter, no
account. **S1 FIXED** — `ACCESS_BACKGROUND_LOCATION` was declared and never once
requested, so never granted, so removing it could not change behaviour; it only
removed the obligation to justify one of the most scrutinised permissions on
either store. S2 (map tiles disclose position to the tile server) and S3 (route
logs stored unencrypted in app-private storage) are stated and accepted.

---

## 5. Iran constraints and their consequences

`docs/IRAN-CONSTRAINTS.md`. The ones with teeth:

* **No Firebase anywhere**, and it must stay that way. Nothing to remove.
* **`forceLocationManager` was `false`**, routing Android through the Play
  Services fused provider. Flipped to `true` — §18.2 independently says fused
  smoothing and road-snapping is "wrong for measurement".
* **Offline map tiles are blocked on a decision.** `map_screen.dart:73` fetches
  live from `tile.openstreetmap.org`, and the OSMF policy **explicitly
  prohibits** the pre-seeding the existing `FileTileProvider` TODO plans. That
  TODO cannot be completed as written.
* **`minSdk = 23` and `IPHONEOS_DEPLOYMENT_TARGET = 12.0`** are deliberate
  floors for older Iranian handsets. **Flutter's migrators rewrite both on every
  native build** — run `git status` after any of them.
* **iOS distribution is the structural risk.** Third-party Iranian stores
  re-sign the binary and Apple revokes those certificates, which stops every
  installed copy at once.

---

## 6. Screenshot trail

65 images in `/tmp/shots/`. The pairs that carry the argument:

| Before | After | Shows |
|---|---|---|
| `00-baseline.png` | `rel_03_cluster.png` | Baseline cluster vs the final release build |
| `09.png` (79 px overflow) | `p2_portrait_gps.png` | Portrait overflow gone in the worst state (`TUNNEL · EST`) |
| `11.png` | `p2_portrait_night.png` | Night mode, no overflow |
| — | `p3_rationale_landscape.png` | The rationale screen that now precedes the prompts |
| — | `p3_prompt.png` → `p3_denied_cluster.png` | Deny both, app still opens reading `GPS LOST` |
| — | `rel_05_settings_bottom.png` | Release build: no DEBUG section, no simulated drive |

---

## 7. Backlog — proposed, NOT approved

| | Item | Why it is not done |
|---|---|---|
| P9 | `geolocator` 13→14, `flutter_map` 7→8, `riverpod` 2→3 | Three major bumps do not belong in a review branch. Own branch, after merge |
| B7 | In-app retry for a denied permission | Product call. Re-showing the screen nags anyone who denied on purpose |
| §8 | Moving average alongside the overall one | Saam chose overall-only-but-labelled; the tile now reads `AVG (ALL)` |
| §6.1 | Revisit the noise floor for degraded reception | **Needs the road-test number first.** Tuning against a synthetic fixture is guessing, and the same floor is what makes parked drift exactly 0.0 |
| — | Localisation (fa, RTL, Persian-Indic digits) | Blocked on B3 — the digits *are* the product, and only Amirali knows what crews expect |

---

## 8. The three things most likely to bite in the next month

1. **The road test fails item 1.** Location OFF→ON recovery is the one fix whose
   code path is certain but whose on-device behaviour could not be reproduced
   either way on an emulator. **A failure there reopens Phase 3.** Everything
   else on the list is a Phase 4 ticket by comparison.
2. **The signing key.** The release APK is signed with the **debug** keystore.
   An app first installed under a debug key cannot be updated with a real one
   without uninstalling — which wipes every tester's trips. This gets harder to
   fix the longer testers accumulate data.
3. **The tile source.** Offline maps are a hard requirement for rally use and
   are blocked on a decision nobody has made. The existing plan in the code is
   not merely unfinished, it is **prohibited by OSMF policy**, so the TODO
   cannot be completed as written.

---

## 9. What is NOT verified, and cannot be from here

* **No road test has ever happened.** Every accuracy figure comes from fixtures
  where ground truth is exact by construction, or from an emulator.
* **The app has never run on iOS.** It compiles for the simulator; that is all.
* **Urban canyon under-reads by 12.50 %** and the road test has to produce the
  real number before §6.1 is touched.
* **Method note, for honesty:** Phase 4's `/design-review`, `/site-qa`,
  `ui-ux-pro-max` and the `mobile-developer` subagent were not used. The UI was
  audited from the live emulator and the 65 screenshots instead. Findings are in
  `docs/PHASE4-AUDIT.md` either way.
* **Phase 5 steps 2, 4 and 5 have not run.** `/codex:review` and
  `/codex:adversarial-review` are `disable-model-invocation`. The self-review in
  their place found and fixed §3.2 and §3.8 above.
