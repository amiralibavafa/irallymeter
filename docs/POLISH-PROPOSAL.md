# POLISH PROPOSAL — Saam chooses, nothing here is built

Stage 5 of the production-quality pass. Everything in this document is
**proposed and NOT implemented.** Approved items go to a new `SA-V3` branch, so
`SA-V2` stays a clean set of correctness fixes and this stays separable.

Ranked by impact per unit of effort, not by severity. Every claim below was
checked against the source rather than written from the audit notes.

State: `SA-V2` `5e4ddc3`, 399 pass / 1 skip / 0 fail.

---

## 1. C16 — number fields change width mid-drive, and one SHRINKS

**The strongest candidate, and the only one that affects reading the instrument
while moving.**

`Formatters` pads nothing: `speed()` goes 1 to 2 to 3 characters, `trip()` 4 to
6, `accuracy()` 2 to 6, `legTime()` leaves minutes unpadded, and `distance()`
(`formatters.dart:29`) switches **unit and format** at 1000 m, so `847 m`
becomes `1.00 km`.

Worse, `InstrumentBox` wraps its child in `FittedBox(fit: BoxFit.scaleDown)`
(`instrument_box.dart:81-82`). `scaleDown` only ever shrinks. So when Trip A
crosses 99.99 into 100.00 the readout does not merely shift, **it gets
physically smaller**, and it never grows back until the tile is rebuilt with a
shorter value.

A co-driver reads these by shape at a glance on a moving car. A digit group
that jumps and resizes is read wrong before it is read right.

**Proposed:** fixed-width formatting for the four live fields, so the character
count never changes within a mode. That removes the trigger for the shrink
without touching `FittedBox`, which still earns its place as the guard against
a genuinely oversized value.

**Cost:** small, and well covered — `formatters` already has tests, and
`screen_layout_test` would catch a regression in the layout.

**Note this is a JUDGEMENT CALL, not a defect.** Fixed width means `007` where
today you get `7`. Some crews prefer the leading zeros of a rally tripmeter;
some find them noisy. **If you dislike the look, say so and this drops off the
list entirely** — nothing depends on it.

---

## 2. C18 — night mode is incomplete, and this partially corrects me

I previously reported night mode as verified. **That was incomplete rather than
wrong: I checked the cluster, and the cluster is correct.**

`AppColors.textPrimary` is the **day** token. Widgets that read it directly
bypass `InstrumentColors` and stay full white on a night screen. There are
**12 such direct reads** across the map, section log, settings and stage timer.

On a night stage the map's LAT/LON/ALT, the GNSS HEALTH figures and the split
times all stay at day brightness. On a windscreen at night that is a glare
source in the driver's field of view.

**Proposed:** route those 12 through `InstrumentColors.of(context)` like the
cluster already does.

**Cost:** small and mechanical, but it touches four screens, so it wants a
screenshot pass in both modes rather than a test.

---

## 3. C17 — five live numbers have no tabular figures

`_tabular` is applied to `displayLarge`, `displayMedium`, `displaySmall` and
`headlineMedium` only (`app_theme.dart:55-70`). Missing on the GPS accuracy and
tunnel estimate in the top bar (updates at 1 Hz), **the entire GNSS HEALTH
panel**, the calibration factor and error, and the countdown target.

Without tabular figures every digit has its own width, so a 1 Hz readout
shimmers as the numbers change even when the value is stable.

**Proposed:** extend `_tabular` to those styles.

**Cost:** trivial. This is the cheapest item on the list.

**Worth pairing with item 1** — both are about a number that will not sit still,
and together they are one coherent change to how the instrument reads.

---

## 4. C19 — touch targets under 44 dp

Two real ones, both verified in `docs/UI-INVENTORY.md`:

- **the speed UNIT label**, which toggles km/h and mph, is a bare `Text` at font
  26 (16 in compact), so roughly a 30 px and 19 px target
- **`TARGET … TAP TO EDIT`** on the stage timer, about 23 px

Several `OutlinedButton` / `TextButton` sit at the Material default of 40 px.
Nav icons, the correction pad, the map FABs and the timer buttons all pass — the
48 px floor there is deliberate and was defended during the portrait fix.

**Proposed:** wrap the two small ones to a 44 px minimum.

**Cost:** small. **But note the speed-unit toggle is a hidden gesture either
way** — nothing on screen says the unit is tappable. If you want that
discoverable, that is a design change and belongs in a conversation with
Amirali, not in a polish branch.

---

## 5. C21 — dead code

`Formatters.distancePrecise` (`:51`) and `Formatters.speedPrecise` (`:68`) have
**zero callers in `lib/` or `test/`** — confirmed by grep just now, not assumed.

**Proposed:** delete both.

**Cost:** trivial, and it is Amirali's code rather than mine, so it is his call
whether they were staged for something.

---

## Reported only — NOT proposed

**C20 — locale and RTL are entirely absent.** `app.dart:44-49` has no
`supportedLocales`, no `localizationsDelegates`, no `flutter_localizations`.

This is **not** on the list because it depends on question B3 to Amirali:
whether Iranian crews want Persian-Indic digits or Latin numerals with
translated labels. For a rally computer **the digits ARE the product**, so this
is a market question before it is an engineering one, and it cannot be answered
from here. Nothing can go wrong today either way, because `Formatters` uses
locale-independent `toStringAsFixed` and `padLeft`.

**C12 — magnetic interference detection.** Reported in `ROAD-TEST.md` section 6
and deliberately not built: `sensors_plus` exposes no sensor-accuracy channel,
so it is a native addition on both platforms.

**D1 — an imported GPX can never be seen.** From `docs/UI-INVENTORY.md`. This is
a **missing feature, not polish**, and it is a question for Amirali: is
following an imported route in scope at all? Listed here only so it is not lost
between documents.

---

## Recommendation

**Take 1 + 3 together, and 5.** They are one coherent change to how the numbers
read plus a two-line deletion, all covered by existing tests.

**Take 2 if there will be a night stage**, and budget a screenshot pass for it.

**Leave 4** until the speed-unit gesture has been discussed with Amirali —
enlarging a target nobody knows is there fixes the smaller half of the problem.
