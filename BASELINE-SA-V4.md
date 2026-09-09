# BASELINE — SA-V4 accounts/auth/payment work

**This file is the LIVE gate. It is re-run after every phase and rewritten each time.**

It is deliberately NOT `BASELINE.md`. That file is the frozen pre-audit record captured
2026-08-03 against `main` @ `c151ca2`, and its own header says anything recorded there as
failing or skipped is PRE-EXISTING and "must never be 'fixed' by weakening an assertion".
A frozen record and a gate that gets rewritten six times cannot share one file, so they do
not. Nothing in `BASELINE.md` has been edited except one pointer line at its end.

---

## The preservation contract, stated as a number

The brief's highest-priority constraint is that the rally computer is not touched. The
mechanical test of that is this line, which must be identical before and after every phase:

```
00:43 +433 ~1: All tests passed!
```

**433 pass / 1 skip / 0 fail.** The 1 skip is `road_scenarios_test` case 12 and it stays
skipped at full strength; it is not to be un-skipped, weakened, or "fixed".

`flutter analyze` must stay at **exactly 2 issues**, both pre-existing:

- `lib/features/settings/presentation/settings_screen.dart:492:11` — `activeColor` deprecated
- `test/distance_speed_test.dart:263:23` — unused optional parameter `stored`

---

## Captured 2026-09-08, branch `SA-V4`, before any accounts code was written

| Check | Command | Result |
|---|---|---|
| Test suite | `flutter test` | **433 pass / 1 skip / 0 fail** ✅ |
| Static analysis | `flutter analyze` | **2 issues**, both listed above ✅ |
| Working tree | `git status` | clean |
| `origin/main` | — | untouched at `c151ca2` |

The three `GPS stream error (Exception: always fails) — re-subscribing…` lines printed
during the run are the watchdog test deliberately provoking failure. They are expected
output, not errors.

## Re-run it

```sh
cd "/Users/saamsani/0xDEAD/Saam&Amirali/irallymeter"
flutter test 2>&1 | tail -4
flutter analyze 2>&1 | tail -4
```

**If either number moves, STOP and revert.** Per the brief: do not "fix" the rally code to
make a number match, and do not weaken an assertion to make a test pass.

---

## Phase log

| Phase | Date | Tests | Analyze | Notes |
|---|---|---|---|---|
| Pre-work capture | 2026-09-08 | 433/1/0 | 2 | Baseline. No accounts code written yet. |
