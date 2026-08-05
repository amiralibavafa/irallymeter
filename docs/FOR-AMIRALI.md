# For Amirali — what changed, and what I need from you

Hi Amirali. This is the short version. Every claim here is either a measured
number or is labelled as not measured, because a few of them look similar and
the difference matters.

---

## 1. Which branch to pull

```bash
git fetch origin
git checkout SA-V3
```

**`SA-V3` is the one.** `main` is untouched at `c151ca2` — your original commit,
exactly as you left it. Nothing has been force-pushed and no history rewritten.

Two branches, on purpose, so you can review and take them separately:

| branch | what it is |
|---|---|
| `SA-V2` | **correctness fixes only.** 123 files, +17,168 |
| `SA-V3` | branches off `SA-V2`. Polish, tests, iOS, review fixes. 37 files, +1,690 |

**No PR is open.** That is deliberate — it is yours and Saam's to open and merge,
not mine.

---

## 2. The numbers

| | Before | Now |
|---|---|---|
| unit + widget tests | 354 pass / 1 skip | **414 pass / 1 skip / 0 fail** |
| integration tests | none existed | **5 / 5 green** on a device |
| golden tests | none existed | **4** + a determinism test |
| `flutter analyze` | 2 issues | **2 issues**, the same two |
| iOS | never built | **builds, installs, launches** |

---

## 3. The five that would have bitten a crew

**Before and after, in the order they would hurt you.**

### The tap that wiped your trip
- **Before:** a single **tap** anywhere on a trip tile zeroed it. The tile is
  about 40 % of the cluster in landscape. The only guard was lock mode, which is
  **off by default**.
- **After:** long-press. The method was **renamed** as well as rebound — it was
  called `_confirmReset` and confirmed nothing, which is how it survived review.
- Three things in your code disagreed: the `onTap` binding, that method name,
  and the class doc that already said *"reset on long-press"*. The doc was right.

### Zero distance through a tunnel, on some phones
- **Before:** receivers that report `0.0` for Doppler speed (they exist, and
  your own comment names them) measured open road fine, then entered a tunnel
  **anchored at zero and accrued nothing** for its whole length.
- **After:** the emit site uses the same `dopplerUsable` test that sits three
  lines above it.
- Now **proven**, not just reasoned: putting the old line back fails the new
  tunnel test and nothing else.

### The compass lied while you were stopped
- **Before:** once the car had moved, the GPS course stayed "valid" for the rest
  of the app's life. Stop, and the cluster showed a **frozen old heading still
  labelled `GPS`**.
- **After:** the source releases below 0.8 m/s and re-acquires above 1.4. The
  gap between those two numbers is deliberate — a single threshold would make
  the label flicker.

### `STREAM STALLS` could never move
- **Before:** the counter had **no caller at all**, so it read 0 forever, and
  the road-test procedure asks a tester to check that exact field. That check
  could not fail. **This one was mine**, not yours.
- **After:** wired, and it distinguishes a tunnel (silence, services up) from a
  real stall (silence that survived services going off and on).

### The trip readout shrank as you drove
- **Before:** measured on a 360×110 tile — `9.99` renders **67.0 px** tall,
  `100.00` renders **50.4 px**. Crossing 100 km shrinks the number you read
  aloud by **25 %** and moves the decimal point **83 px**.
- **After:** the field reserves the widest value's width. **No leading zeros** —
  `7.35` still reads `7.35`, not `007.35`. Say the word if you want the classic
  tripmeter zeros; it is a one-line change.
- On a wide screen the effect is 72.0 vs 71.9, which is why nobody caught it.

**Also fixed:** true-north calibration never actually learned · the speedometer
showed readings the odometer threw away · the GNSS health panel was frozen at
whatever it read when you opened it · night mode never reached four screens ·
`SafeArea` missing on the map, where the app runs on a windscreen mount · every
settings row was dead to the touch (no ink splash) · the countdown was stuck at
1:00 because `setCountdownTarget` was never called.

Full detail with file references: **`docs/QA-REPORT.md`**.

---

## 4. Things I did NOT change, on purpose

- **The wakelock.** Reviewed and left alone. Scoping it to a trip needs a
  concept of an active trip that the app does not have, and a cluster that
  blanks at a control is worse than a lit screen in a service park.
- **Persian-Indic numerals.** For an Iranian crew the digits *are* the product.
  That is your call, not a code decision.
- **Touch targets on the speed-unit toggle.** Enlarging a gesture nobody knows
  exists fixes the smaller half. Worth a design conversation first.

---

## 5. What I need from you

**Two are time-sensitive. The rest can wait.**

### Urgent

1. **Whose signing key, and where is it kept?**
   The release APK is currently **debug-signed**. An app first installed under a
   debug key **cannot be updated with a real one without uninstalling**, which
   wipes every tester's saved trips. This has to land *before* testers build up
   data worth keeping.

2. **iOS 12 or iOS 13?**
   The Flutter iOS migrator raised `IPHONEOS_DEPLOYMENT_TARGET` from **12.0 to
   13.0** on the first build. It is not optional — current Flutter does not
   support iOS 12 — but it changes which handsets can install the app, and you
   had asked for a 12 floor. Confirm you accept 13, or we pin an older Flutter.

### Product calls

3. **Which map tile source?** The offline TODO in the code **cannot be done as
   written** — the OpenStreetMap Foundation policy prohibits the pre-seeding it
   plans. This is a licensing constraint before it is a preference.
4. **Persian-Indic digits, or Latin numerals with translated labels?**
5. **Is following an imported GPX route in scope?** Right now a route can be
   imported and then only exported or deleted — **nothing anywhere draws it**.
   Importing a route implies driving it, so this will get reported as a bug.
6. **Should the trip counters be settable to a value?** They can be zeroed and
   nudged, never set. A regularity restart normally means entering a known
   distance.

### Two spec readings (§12.2)

7. Does §12.2 **saturate** at the ceiling, or snap back to v₀? The literal
   reading sawtooths 25 → 20 → 25, which on a driver-facing readout looks like a
   fault.
8. Should it apply **upwards only**? Symmetric would hold a stopped car at v₀
   and invent distance.

---

## 6. What still has to happen, and it needs a car

**No road test has ever been done.** Every accuracy number in this repo comes
from generated fixtures or an emulator, where the ground truth is exact by
construction. `docs/ROAD-TEST.md` is the procedure.

**Item 1 is stop-ship**: whether the trip counter can fail to come back after
location services are switched off and on. If that fails, it reopens the work.

The three code-review findings that sat on the measurement path are now **fixed**
and were the last blocking work:

- **GPS errors never reached the error display.** The retry loop turned every
  platform failure into the same value a tunnel produces, so a revoked
  permission read as `GPS LOST`. Three tests covered that error state and all
  three passed — none of them went through the real service.
- **The moving average roughly doubled at 5 Hz.** Measured **39.96 m/s on a car
  doing 20**. The distance and the ordinary average were both correct, which is
  why it could sit next to a readout that looks right. It got worse the faster
  the receiver.
- **A 10-minute reconnect fired inside a long tunnel.** The limit's own comment
  named Lærdal at 1102 s against a 600 s limit. Now 30 minutes, and a
  silence-only reconnect is no longer recorded as a fault.
