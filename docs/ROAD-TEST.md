# ROAD TEST PROTOCOL

Everything in this audit was measured in replay or on an emulator. **§20.2 has
not happened.** This is the list of what a real drive has to answer, ordered so
the highest-value unknowns come first.

Take screenshots. A number you remember is not evidence.

---

## Before you set off

- Install the `SA-V1` build. Confirm Settings → DEBUG → **Simulated drive is
  OFF** (it is debug-only and off by default, but check).
- Reset Trip A and Trip B at a known landmark.
- Note the odometer reading and the time.

---

## 1. THE ONE THAT MATTERS MOST — does the trip counter ever stop coming back?

`[3.14]` fixed a defect where the position stream, once silent, could never
recover: the app sat in Estimation Mode with a **frozen trip counter and a red
`EST?` badge** until it was restarted. The code defect is certain. **The fix is
NOT verified end to end** — I could not isolate it from emulator behaviour.

**Do this deliberately, twice:**

1. Driving normally, pull over. Turn the phone's **location services OFF** for
   about a minute, then back ON. Do **not** restart the app.
2. Drive on for two minutes.

**PASS:** within ~20 s of location returning the badge clears, the status bar
goes back to `GPS ±Nm`, and the trip counter starts advancing again.
**FAIL:** it stays amber/red and the trip stops counting. **If it fails, say so
immediately — that is a stop-ship bug, not a polish item.**

Repeat once in a real tunnel, where the same silence happens naturally.

---

## 2. Tunnels — the whole point of this revision

Niayesh (6 658 m) or Alborz (6 400 m) are ideal because both take longer than
the old 5-minute cap that `[3.13]` removed.

Record for each tunnel:

| | |
|---|---|
| Trip A entering the portal | |
| Trip A leaving the portal | |
| Actual tunnel length (signage or map) | |
| Did the digits go **amber** with `EST`? | |
| For a >3 min tunnel, did they go **red** with `EST?` | |
| Did the counter ever **jump** on recovery? | |
| Did it ever go **backwards**? | |

**PASS:** distance through the tunnel is within ~3 % of the real length, the
estimated state was obvious at a glance, and the correction on recovery was
invisible — no jump, no reversal.

**Known limitation to watch for:** the estimate is anchored to the speed at the
portal. If you brake hard just inside, the estimate will run long. §12.2's
accelerometer refinement should absorb some of that — this is the first real
chance to see whether it does.

---

## 3. The §6.1 trade-off — the biggest known gap

Replay found the engine **under-reads** in two situations, both from the same
rule (§6.1 rule 3 ignores displacement smaller than the fix's own accuracy):

- **stop-start traffic: −5.0 %**
- **urban canyon: −16.7 %**

Drive a **measured city section** — motorway distance markers, or a route you
know to the 100 m — through traffic and between tall buildings.

**Report the actual percentage.** If real-world under-reading is anywhere near
16 %, §6.1 rule 3 needs a decision from Amirali, and this measurement is what
that decision should be based on. Do not adjust anything before measuring.

---

## 4. Curved roads

Replay says 20 hairpins at r = 30 m cost **−0.75 %**. Drive a genuinely twisty
section against a known distance and report the number. §19 defers a calibration
factor for exactly this; the field number decides whether it is needed.

---

## 5. Accuracy over a long day

Drive **50 km or more** against measured markers.

**Target (§19 row 1): error ≤ 1.0 %.** Report the raw numbers, not the verdict.

---

## 6. The compass

`[3.11]` changed two things and did not fix a third.

- **Lag:** the needle should now settle in about a second and behave the same on
  any phone. Does it still feel laggy?
- **True north:** turn "Use true north" ON. It will say `MAG` until it has
  learned the offset from GPS course, which needs roughly 20 seconds of driving
  above 18 km/h. After that it should say `TRUE`. **Does it ever switch?**

  Read this one carefully, because it used to be untrue. Before `[SA-V2 30]`
  (C4) the calibration was never even created while the car was moving, and
  moving is the only time it can learn, so on most drives it learned nothing and
  said `MAG` forever. It now learns from app start whether or not the switch is
  on, so turning the switch on mid drive should show `TRUE` almost immediately.
- **The agreement threshold, and it is UNMEASURED.** `[SA-V2 31]` (C5) added a
  second condition: `TRUE` now also requires the observations to agree with each
  other, because twenty contradictory ones used to earn it exactly as readily as
  twenty consistent ones. The numbers are 12 degrees of mean residual to earn
  `TRUE` and 20 to lose it, and **both were reasoned, not measured.** This drive
  is where they get real values.
  - If the compass sits on `MAG` all day in a mount that is clearly fine, 12 is
    too tight.
  - If it says `TRUE` while the heading is visibly wrong, 12 is too loose.
  - If the label flips between `TRUE` and `MAG` while driving, the band between
    12 and 20 is too narrow.
- **NOT fixed:** tilt compensation uses the raw accelerometer, so heading is
  expected to wander while accelerating, braking and cornering. **Does it?**
  That is the remaining known cause.

---

## 7. The things nobody has tested at all

- **Screen off, in a pocket or on the mount, for a long drive.** Does the
  foreground service survive? Does the trip keep counting? (§19 row 6 and §20.3
  both ask; neither has been measured.)
- **Android battery optimisation ON.** Same drive. This is §18.4's "one
  remaining platform issue" and it cannot be solved in code.
- **iOS.** The project builds for the simulator and has never been run there.
- **A fresh install.** Watch for the first-run splash hang (P1). It did not
  reproduce on a clean reinstall, so it is an intermittent race — if you ever see
  the app stuck on the Flutter logo, that is it, and it is worth reporting.
- **The map.** It fetches tiles live and has no offline support. Expect it to be
  blank where there is no data — that is `docs/IRAN-CONSTRAINTS.md` §4, not a
  new bug.

---

## Reporting back

For each item: what you did, what the numbers were, and a screenshot. Anything
that fails item 1 or produces a visible jump/reversal in item 2 is urgent;
everything else is tuning.
