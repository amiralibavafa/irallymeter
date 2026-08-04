# AGENTS.md — iRallyMeter

Instructions for AI agents working in this repository. **Codex does not read
`CLAUDE.md`; this is the file it reads.**

iRallyMeter is a Flutter rally trip computer. The product is a number a
co-driver reads aloud at speed and acts on. Accuracy is not a feature here, it
is the whole thing.

---

## Ownership boundary

**Claude Code owns `docs/` and the memory files. Codex may READ them and must
never write them.** If a review finds something wrong in `docs/`, report it —
do not edit it.

Everything under `lib/`, `test/`, `tool/` and the platform folders is fair game
for either.

---

## Commands

```bash
flutter analyze          # must stay at 2 pre-existing issues, no new ones
flutter test             # must be green
dart run tool/generate_fixtures.dart   # regenerates test/fixtures/*.jsonl
```

There is **no `npm test`**. There is no CI in this repo yet.

Current baseline: **295 pass / 3 skip / 0 fail**.

---

## Branches

**Never commit or push to `main`. Never force-push. Never rewrite a pushed
branch.**

Work goes on `SA-V<n>`:

* `SA-V1` — the Phase 3 backend work
* `SA-V2` — approved Phase 4 UI fixes

A hyphen, not a space: git ref names cannot contain spaces, and the original
convention (`SA V1`) is impossible. Confirmed with the repo owner.

Stage **explicit paths**. `git add -u` counts as `git add -A` here and has
already swept an unrelated Android regression into a commit.

---

## The three skipped tests are deliberate. Do not "fix" them.

1. `dashboard_layout_test` 02 — portrait top-bar overflow. **Pre-existing, and
   the repo owner's own skip.**
2. `dashboard_layout_test` 05 — was passing **vacuously**; its `TUNNEL` finder
   matched a button that §15 deleted. Cannot pass until
   `DistanceEngineController`'s wall clock is injectable.
3. `road_scenarios_test` 12 — urban canyon reads **−12.50 %**. Asserted at
   **full strength** against §19's 1 %. It is a known, measured limitation
   awaiting a road-test number, not a broken test.

**Weakening any assertion to make a suite green is the one thing that will get a
change rejected outright.** If a test fails, either the code is wrong or the
test encodes a decision — say which.

---

## Things that look like bugs and are not

* **`minSdk = 23`** in `android/app/build.gradle` and
  **`IPHONEOS_DEPLOYMENT_TARGET = 12.0`** are deliberate floors — this app ships
  to Iran where older handsets are common. **Flutter's migrators rewrite both on
  every native build.** Run `git status` after any `flutter build`/`flutter run`
  and revert what the migrator touched.
* **`forceLocationManager: true`** is intentional. SPEC-v2 §18.2: fused
  location's smoothing and road-snapping is "wrong for measurement".
* **A Doppler speed of exactly `0.0` is not trusted to veto a displacement.**
  Platforms with no speed support report `0.0`, not null — gating on it makes
  those devices measure nothing.
* **The `EST` / `EST?` / `SYNC` badge is TEXT, not just colour.** At night the
  whole palette is amber-red and the colour signal collapses; the text is the
  only thing that still differentiates. Do not "simplify" it to a colour.
* **`GpsSample.noFix()` heartbeats** are emitted every 20 s of silence on
  purpose, so the UI can show a gap without tearing down the subscription.

---

## The rules the domain actually runs on

Read `docs/SPEC-v2.md` before changing measurement behaviour. The five that bite:

1. **A tunnel is silence.** Never add a timeout, retry or watchdog to the GPS
   path without first asking what it does *inside a tunnel*. A flat
   `.timeout()` once restarted the Android foreground service ~20× inside one
   400 s tunnel — attacking the service that keeps the app alive in there.
2. **§6.1 rule 3 must not destroy data.** The noise floor is the fix's own
   accuracy, and a rejected displacement **holds the anchor** so small real
   movements accumulate. Re-anchoring on rejection discarded everything below
   `accuracy × fixRate` — at 5 Hz that was everything below 90 km/h.
3. **Distance never goes backwards.** §16.1 corrects undershoot only; an
   overshoot proves nothing, because the entry→exit chord is a lower bound.
4. **The engine is pure Dart** (§17). `lib/features/distance/domain/` imports no
   Flutter, no plugins, no `dart:io`. A test asserts this structurally.
5. **Filters are time-based, not sample-based.** A per-sample EMA makes latency a
   property of the device's sensor rate. Both the speed display and the compass
   were wrong this way.

---

## What a good change looks like

* One behaviour change at a time, with `flutter analyze` clean and
  `flutter test` green before the next one.
* Ground truth in tests is **exact by construction**, not measured — see
  `tool/generate_fixtures.dart`.
* When a rule rejects an input, say what happens to the state it would have
  advanced.
* Vary the sample rate and accuracy in tests. Every fixture used to be 1 Hz at
  20–25 m/s, which is how a catastrophic bug survived fourteen steps.

---

## What has NOT been verified

Say so rather than assuming otherwise:

* **No road test has ever happened.** Every accuracy figure comes from generated
  fixtures or an emulator.
* **The app has never run on iOS.** It compiles for the simulator; that is all.
* Recovery from location services being toggled off and on is **unproven on
  hardware** — see `docs/ROAD-TEST.md` item 1.
