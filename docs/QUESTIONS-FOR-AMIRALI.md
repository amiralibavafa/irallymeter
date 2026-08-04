# QUESTIONS FOR AMIRALI

Everything from Phases 3 and 4 that needs **your** answer, in one place. Nothing
here is blocked on more work from our side — each one is a decision only you can
make, either because it is your product or because it needs a real drive.

Branches: `SA-V1` (backend, 295 pass / 3 skip) and `SA-V2` (four contained UI
fixes). Neither is merged.

---

## A. Two deviations from a literal reading of §12.2 — please confirm or reject

Both are already implemented the way described. Both are flagged in the code and
the commit messages. **Neither blocks anything.**

**A1 — the ±25 % clamp SATURATES rather than snapping back to v₀.**
§12.2 says "clamp … if the correction wants to exceed this, ignore it and hold
v₀". I built the literal snap-back first and my own test caught that it
**sawtooths**: the estimate climbs to 25, drops to 20, climbs again, settles at
22. On a driver-facing speed readout that looks like a fault. Saturating at the
ceiling is the plain reading of "clamp".
**Is saturate what you meant?**

**A2 — the ±25 % bound is applied UPWARDS ONLY**, so deceleration runs all the
way to a stop. Applied symmetrically it would hold a car braking to a halt at
v₀ and invent distance, and your own `tunnel_system_test` 11 already asserts the
estimate "must settle at a clean stop". The risk is asymmetric: an
**over-estimate is permanent** (the engine reconciles undershoot only), while an
under-estimate recovers on the next fix.
**Confirm upwards-only?**

---

## B. Product decisions

**B1 — Is PORTRAIT a supported orientation?**
The top bar overflows by 70 px normally and **137 px in Estimation Mode** (it
scales with the status text). Landscape — the co-driver configuration — is
completely clean in both day and night mode. Closing portrait means shrinking
glove-sized touch targets or dropping something from the top bar.
Saam's view is "support it, fix the layout". **Do you agree, or is
landscape-only the honest answer?**

**B2 — Which MAP TILE SOURCE?**
This blocks offline maps entirely, and offline is a hard requirement for rally
use. The app currently fetches tiles live from `tile.openstreetmap.org`, and the
OSMF policy **explicitly prohibits** the pre-seeding that the existing
`FileTileProvider` TODO plans — it names "Download city/country for offline use"
as not allowed. So that TODO cannot be completed as written.
Options ranked in `docs/IRAN-CONSTRAINTS.md` §4. My recommendation: keep
`flutter_map`, change only the source, most likely Neshan or Map.ir with a
side-loaded pack. **Your call.**

**B3 — LOCALISATION: do Iranian rally crews want Persian-Indic digits?**
There is currently no localisation at all — no `supportedLocales`, no RTL. This
is the one question I genuinely cannot answer: rally road books and tripmeters
are conventionally read in Latin digits, and the digits *are* the product. It is
entirely possible the right answer is **translate the labels, never the
numbers**. **What do crews actually expect?**

**B4 — §8: do you want a MOVING average as well as the overall one?**
The spec names both. Saam chose overall-only-but-labelled — the tile now reads
`AVG (ALL)` — because a second tile costs space on a top bar that already
overflows. The engine change is about ten lines. **Add the second one, or leave
it?**

**B5 — iOS posture.** Iranian third-party iOS stores re-sign your binary, and
Apple revokes those certificates regularly — when it happens **every installed
copy stops working at once**. Nobody has ever run this app on iOS; it only
compiles for the simulator. **Is iOS a shipping platform, or Android-first with
iOS best-effort?**

**B6 — confirm two floors are deliberate**, because Flutter's migrators keep
trying to raise them and I keep reverting them:
`minSdk = 23` (Android 6.0) and `IPHONEOS_DEPLOYMENT_TARGET = 12.0`. Raising
them drops older handsets. **Keep both?**

---

## C. Which Phase 4 items should we build?

`SA-V2` already has the four that needed no decision: the launch-hang guard, the
OSM User-Agent, the app label, and removing an unused dependency. These are the
ones still waiting:

| | Item | Effort |
|---|---|---|
| P2 | Fix the portrait layout | real work — see B1 |
| P3 | A rationale screen before the cold permission prompts (store-rejection risk) | one screen |
| P8 | Injectable clock in `DistanceEngineController` — restores a skipped test that covers the worst-overflow state | ~20 lines |
| P12 | Compass tilt compensation uses the raw accelerometer, so heading wanders while accelerating, braking and cornering | medium |
| P9 | Dependency upgrades — `geolocator` 13→14, `flutter_map` 7→8, `riverpod` 2→3 | own branch, after merge |

---

## D. Things that need a real drive, not a decision

Full protocol in `docs/ROAD-TEST.md`; the pass conditions are in
`docs/PHASE3-SIGNOFF.md`. The short version:

1. **Toggle location OFF for a minute mid-drive, then ON, without restarting the
   app.** The trip counter must start advancing again. This is the one fix whose
   code path is certain but whose on-device behaviour I could not reproduce
   either way on an emulator. **If it fails, Phase 3 reopens.**
2. A real tunnel — Niayesh or Alborz. Distance within ~3 %, no jump or reversal
   on exit, and **STREAM STALLS must still read 0** (Settings → Section log).
3. 50 km against measured markers → §19 row 1 wants ≤ 1.0 %.
4. **Report the error % in city traffic and on a twisty road.** These do not have
   to pass; they have to be measured, because they are the inputs to the §6.1
   and calibration-factor decisions. Tuning either before a real number exists
   would be guessing.

---

## E. For information — no answer needed

* The app would have refused to reconcile the **Niayesh tunnel**: it takes 399 s
  at 60 km/h and the sanity cap was a flat 300 s. Now based on whether the
  inertial stream kept running, so a real tunnel is allowed to be long.
* A **faster GPS used to make the app measure less** — at the 5 Hz the app
  itself requests, everything below 90 km/h was being discarded. Fixed.
* **Resetting a trip** used to drag up to 715 m of the previous leg's tunnel
  correction into the new one. Fixed.
* Your `minSdk = 23` and the pre-existing skipped portrait test were both
  treated as deliberate and preserved throughout.
