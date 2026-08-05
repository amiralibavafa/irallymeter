# QA REPORT — production-quality pass

Written last, on purpose. Everything below is either a measured number or a
statement that a thing was **not** measured. Where those two are easy to
confuse, it says so.

**Branches.** `origin/main` is `c151ca2` and **was never touched**. `SA-V2`
holds the correctness fixes. `SA-V3` branches off `SA-V2` and holds the polish
and the test infrastructure, so the two can be reviewed and merged separately.
**No PR has been opened** — that is Saam's and Amirali's call.

**State at the time of writing:** `SA-V3` = `e2d4e14`, **89 commits ahead of
`main`**, 9 of them on `SA-V3`.

---

## The numbers

| | Before this pass | Now |
|---|---|---|
| Unit + widget tests | 354 pass / 1 skip / 0 fail | **411 pass / 1 skip / 0 fail** |
| Integration tests | none existed | **5 / 5 green** on `emulator-5554` |
| Golden tests | none existed | **4**, plus a determinism test |
| `flutter analyze` | 2 issues | **2 issues**, the same two |
| iOS | never built | **builds, installs, launches** |

The one skip is `road_scenarios_test` 12, held **at full strength**. Softening
it to make the suite look clean would be the wrong trade and it has been
refused each time it came up.

The two analyze issues are pre-existing and unrelated: a deprecated
`activeColor`, and an unused test parameter.

---

## What was actually wrong

Twenty-two findings were investigated. The ones that mattered fall into one
theme, and it is worth stating plainly because it predicts where the next bug
will be:

> **The app asserted things it had not measured, and in most cases a doc comment
> already described the correct behaviour while the code had quietly stopped
> implementing it.**

Reading the comment instead of the code is exactly how C1 was got wrong the
first time.

### The four that lose or falsify data

| ID | Defect |
|---|---|
| **C0** | **A single TAP on a trip tile zeroed it.** Amirali's, from the initial commit, and the worst thing found. The target is ~40 % of the cluster in landscape; the only guard was a lock mode that is **off by default**. Three things contradicted each other: the `onTap` binding, a handler named `_confirmReset` that confirmed nothing, and a class doc saying *"reset on long-press"*. Now long-press, and the method was **renamed as well as rebound** — a lying name is how it survived review. |
| **C1** | **The compass source was a one-way latch, not a hybrid.** After the first moving fix the GPS course stayed finite for the life of the app, so a stopped car showed a **stale frozen course still labelled `GPS`**. The naive fix would have introduced boundary flapping, so the switch has a hysteresis band (acquire 1.4 m/s, release 0.8) — **the gap is the feature**. |
| **C2** | **`noteStall()` had no caller.** So `STREAM STALLS` was permanently 0, and `ROAD-TEST` item 2 depends on that field — the road test would have "passed" a check that could not fail. **This one was mine**, from `[3.18]`. |
| **C3** | **The cold-start seed bypassed `forceLocationManager`.** `getLastKnownPosition()` defaults the flag to false, so the first position shown came from the road-snapping fused provider the rest of the file deliberately refuses. A seed snapped to a road is worse than a stale raw one: it is confidently wrong, and it is what the trip anchor starts from. |

### The rest, in one line each

**C4** the true-north calibration never learned, and said `MAG` — which reads as
its own opposite · **C5** "agreeing samples" were never checked for agreement ·
**C6/C11** the speedometer displayed readings the odometer threw away, and
`NaN <= 0` being **false** froze the needle · **C7** the GNSS HEALTH panel was a
frozen snapshot, which compounded C2 · **C8** the calibration relearned from
zero every launch · **C9** no branch for "no sensor at all" · **C10** the heading
lagged by samples: **60.5° at 5 Hz vs 18.0° at 1 Hz** for the same turn ·
**C13** wakelock reviewed and **deliberately unchanged** · **C14** stream errors
were dropped, so a revoked permission looked identical to a tunnel · **C15**
`SafeArea` missing on the map, where the app runs landscape on a mount ·
**C16** the trip readout **shrank 25 %** crossing 100 km · **C17** five live
numbers had no tabular figures · **C18** night mode never reached four screens ·
**C21** dead code.

**C12 and C19 were reported and NOT built**, as scoped. **C20** (locale/RTL)
depends on Amirali's answer about Persian-Indic digits and is a market question
before an engineering one.

### Five were mine

Stated because a report that only lists other people's mistakes is not an audit.
**C2** was my code. **C1** I had explicitly certified as correct in writing.
**C6's first fix** collapsed the trust questions the other way. **C22 does not
exist** — I invented it writing a task list from memory and it spread to three
files. **C18** I scoped to one of two day tokens and wrote "twelve widgets" when
there were twenty-five.

---

## What the new tests are for, and what they cannot do

**Goldens** catch what rectangle assertions cannot: colour and composition. They
earned their place on their first run by exposing the `textSecondary` half of
C18. **They say nothing about typography** — `flutter_test` substitutes a font
whose glyphs are all one width, so they cannot see tabular figures, a wrong
label, or `120` versus `999`.

**The integration suite** exercises the real boot path: real Hive, real router,
real platform channels. Everything in `test/` fakes at least one of those. It
found a defect on its first green-able run: a `ListTile` inside a coloured
`DecoratedBox` paints its splash on the nearest Material **ancestor**, so the box
swallowed it and **all five settings rows were dead to the touch**.

**It deliberately covers nothing that needs GNSS.** An emulator has no receiver,
and injected location is a synthetic track whose ground truth is exact by
construction — which the replay fixtures already do better.

---

## The three things most likely to bite next

1. **No road test has ever happened.** Every accuracy number in this repo comes
   from generated fixtures or an emulator. `docs/ROAD-TEST.md` is the list, and
   **item 1 is a stop-ship check**: whether the trip counter can fail to come
   back after location services are toggled off and on. A failure there reopens
   Phase 3; it is not a Phase 4 item.
2. **The urban-canyon under-read is −12.50 % and its cause is isolated but not
   fixed.** `[3.16]` fixed the larger half (§6.1 rule 3 was destroying data by
   re-anchoring on rejection). What remains is a different mechanism: when
   accuracy breathes past the integrable limit the engine coasts at v₀ and
   cannot track speed it is not told about. **Measure it on a real road before
   tuning anything.**
3. **Two compass thresholds are reasoned, not measured.** `TRUE` is earned at
   ≤ 12° of mean residual and lost at 20°. Those numbers were argued, not
   observed. `ROAD-TEST.md` §6 asks the tester to write the residual down
   during the drive, because symptoms say a threshold is wrong and never say
   what to change it to.

---

## Decisions that are not ours

| | |
|---|---|
| **`IPHONEOS_DEPLOYMENT_TARGET` 12.0 → 13.0** | Raised by the Flutter migrator on the first iOS build. Not optional — current Flutter does not support iOS 12 — but it changes which phones can install the app, and Amirali was asked to confirm an iOS 12 floor. |
| **The map tile source** | The existing offline TODO **cannot be completed as written**: the OSMF policy prohibits the pre-seeding it plans. A licensing constraint before a preference. |
| **Persian-Indic digits vs Latin** | For an Iranian rally crew **the digits are the product**. Not answerable from here. |
| **Signing-key custody** | The release APK is **debug-signed**. An app first installed under a debug key cannot be updated with a real one without uninstalling, which wipes every tester's trips — so this must land **before** testers accumulate data worth keeping. |
| **Two §12.2 readings** | Saturate vs snap back, and upwards-only. Neither blocks progress. |

All of these, plus the six open product questions, are in
`docs/DECISIONS-TAKEN.md` and `docs/QUESTIONS-FOR-AMIRALI.md` with what would
reverse each.

---

## What is still not done

- **Stage 6 is this document.** Everything before it is complete.
- **The codex passes have not been re-run against final HEAD.** They ran against
  the research vault before most of this existed. Saam runs them; they are
  `disable-model-invocation` and cannot be fired from here.
- **No PR.** Open it against `main` when the codex findings are folded in, and
  **do not merge** — that is for Saam and Amirali.
