# UI INVENTORY

Every interactive element and every rendered value in the app, with `file:line`.

Built by walking the widget tree, not from memory. The point of writing it down
is that a control nobody listed is a control nobody tested, and three of the
findings in this audit were exactly that: a handler with a lying name (C0), a
counter with no caller (C2), and a panel that never rebuilt (C7).

**Read the DEAD ENDS section first.** It is the only part that names things that
do not work.

State as of `SA-V2` `5128fce`. Six routes, defined in
`lib/core/router/app_router.dart:30-39`.

| Route | Screen | Reachable from |
|---|---|---|
| `/` | `dashboard_screen.dart` | app start |
| `/welcome` | `permission_rationale_screen.dart` | first launch only, `onboarded` flag |
| `/timer` | `stage_timer_screen.dart` | dashboard nav |
| `/map` | `map_screen.dart` | dashboard nav |
| `/settings` | `settings_screen.dart` | dashboard nav |
| `/sections` | `section_log_screen.dart` | **settings only** — no dashboard nav |

---

## DEAD ENDS

Controls that work but lead nowhere, and one gap where a value cannot be read.
None of these is a crash; all of them are a user doing something and getting
nothing back.

**D1 — an imported GPX can never be seen.** `settings_screen.dart:271` imports a
GPX into the session list, where it renders a name, a point count and a
distance (`:303-345`). The map draws **only the live recorder track**:
`map_screen.dart:55` builds its polyline from `recording.points`, and nothing
anywhere draws a *saved* session. So a crew can import a route someone sent them,
confirm the app parsed it, and then have no way to follow it. Export it back out
and delete it are the only two things they can do with it.

This is the most likely one to be reported as a bug rather than a gap, because
importing a route strongly implies you are going to drive it.

**D2 — a saved session cannot be re-opened either.** Same cause as D1, milder
consequence: you recorded it, so you have already driven it. Export
(`:328-332`) and delete (`:333-339`) are the only actions.

**D3 — `/sections` has no nav target.** It is reachable only through
Settings → ESTIMATED SECTIONS → Section log (`settings_screen.dart:84`). That
screen carries the GNSS HEALTH panel, which is what `docs/ROAD-TEST.md` asks the
tester to read, so on a road test it is four taps deep from the cluster. Not
wrong, but worth knowing before handing the app to a tester.

**D4 — the trip counters cannot be set, only zeroed and nudged.** `RST A` /
`RST B` (`trip_controls.dart:29`) zero, and the `±10` / `±100` pads
(`:26,:34`) adjust. There is no "set Trip A to 12.34". A rally regularity
restart normally means entering a known distance, so this may be a genuine
missing feature rather than an inventory note — **it is a question for Amirali,
not something to build.**

---

## `/` Dashboard — `dashboard_screen.dart`

### Top bar (`_TopBar`, `:82-120`)

Portrait stacks this into two rows and landscape does not; the reasoning is in
the class doc at `:60-81` and the measured overflow numbers are there too.

| Control | Line | Action | Notes |
|---|---|---|---|
| Clock | `app_clock.dart` | none | display only |
| GPS status badge | `gps_status_bar.dart` | none | display only, see below |
| Day/night toggle | `:100` | `toggleDisplayMode` | persisted |
| Timer nav | `:101` | `push('/timer')` | |
| Map nav | `:102` | `push('/map')` | |
| Settings nav | `:103` | `push('/settings')` | |
| Lock toggle | `:104` | `toggleLock` | session-only, not persisted |

All five are `IconButton` with `minWidth/minHeight: 48` (`:93-96`), so they meet
the glove-target bar. **The 48 px floor is deliberate and load-bearing** — the
portrait fix documented at `:60-81` explicitly refused to shrink them.

### Lock overlay (`_LockOverlay`, `:238-258`)

| Control | Line | Action |
|---|---|---|
| Whole screen | `:246` | `onTap: () {}` — swallows taps, by design |
| Whole screen | `:253` | `onLongPress` → `setLocked(false)` |

The empty `onTap` is **not** dead code: it is what stops taps reaching the
instruments underneath. Long-press is the only way out.

### Instruments

| Tile | File | Rendered value | Gesture |
|---|---|---|---|
| Speed | `speed_display.dart` | km/h or mph, tabular | **tap on the UNIT** toggles metric/imperial (`:80`) |
| Heading | `heading_display.dart:21-27` | `CAP • GPS`/`MAG`/`TRUE`/`--`, 3 digits + cardinal | none |
| Trip A / Trip B | `trip_panel.dart` | distance | **LONG-press** resets (`:46`) |
| ODO | `trip_panel.dart:105` | odometer | none — reset lives in Settings |
| AVG (MOVING) | `average_speed_display.dart:52` | moving average | **LONG-press** resets (`:55`) |
| Measurement badge | `measurement_badge.dart` | `EST` / `EST?` | display only |

**The two long-presses are the C0 fix.** Both were `onTap` on the whole tile,
which in landscape is roughly 40% of the cluster. `instrument_box.dart:51-52`
now exposes `onTap` and `onLongPress` separately, and its doc says destructive
actions belong on the second one.

**The speed-unit tap target is small** — the gesture is on a bare `Text`
(`speed_display.dart:80-90`) whose font is 26, or 16 in compact (`:85`), so the
rendered target is roughly 30 px and 19 px. That is C19, in the Stage 5 polish
proposal, not fixed here.

### Trip controls (`trip_controls.dart`)

`-100 / -10 / RST A / +10 / +100`, and the same row for B. `_ResetButton`
(`:29`) is a plain button and zeroes immediately, with no confirmation — that is
intentional and it is the reason the *tile* gesture had to become long-press
rather than the button gaining a dialog.

---

## `/timer` Stage timer — `stage_timer_screen.dart`

| Control | Line | Action | Disabled when |
|---|---|---|---|
| Mode toggle STOPWATCH / COUNTDOWN | `:50`, `:98` | `setMode` | while running |
| `-1:00` `-0:10` `+0:10` `+1:00` | `:73`, `:221` | `setCountdownTarget` | countdown off |
| `TARGET … TAP TO EDIT` | `:254`, text `:260` | opens the entry dialog | countdown off |
| START / STOP | `:296` | `ctrl.toggle` | never |
| SPLIT | `:299` | `ctrl.split` | not running |
| RESET | `:301` | `ctrl.reset` | never |

Countdown entry dialog (`_promptForTarget`, `:147-200`):

| Element | Line | Behaviour |
|---|---|---|
| Text field | `:175` | autofocus, **pre-selected** — see below |
| Live validation | `:175` | `errorText: 'not a time'` as you type |
| Enter key | `:184` | submits if parseable |
| CANCEL | `:191` | pops with null |
| SET | `:197` | **disabled** while unparseable |

**The pre-selection is a fix, not a detail.** The field used to be pre-*filled*
without being pre-*selected*, so typing appended to the existing value and gave
`1:004:30`, which then failed to parse and was silently refused. The user saw
nothing happen.

`TARGET … TAP TO EDIT` is about 23 px tall (`:254-270`) — also C19.

---

## `/map` Map — `map_screen.dart`

| Control | Line | Action |
|---|---|---|
| Pan / zoom | flutter_map | disengages follow |
| Follow FAB | `:227` | re-centres, `_follow = true` |
| Record FAB | `:265-280` | start, or stop and save with a snackbar |

| Rendered | Line | Notes |
|---|---|---|
| Tiles | `:103` | **live from `tile.openstreetmap.org`, no offline cache** |
| Live track | `:129-132` | recorder points only — see D1/D2 |
| Heading marker | `:242` | rotates with heading |
| Coordinate bar | `:217` | LAT / LON / ALT |
| Tiles-unavailable banner | `:190` | `MAP TILES UNAVAILABLE · POSITION STILL TRACKING` |

Layout: `FlutterMap` is deliberately full-bleed and only the overlays sit inside
a `SafeArea` (the C15 fix). Wrapping the body would letterbox the map; the
tiles should run under a cutout, the controls must not.

The offline-tile question is **open with Amirali** and is a licensing
constraint before it is a preference: the OSMF policy prohibits the pre-seeding
the existing TODO plans. `docs/IRAN-CONSTRAINTS.md` section 4.

---

## `/settings` Settings — `settings_screen.dart`

| Section | Control | Line | Persisted |
|---|---|---|---|
| DISPLAY | Night mode switch | `:55` | yes |
| DISPLAY | Speed unit | `:60` | yes |
| COMPASS | Use true north | `:66` | yes |
| PERMISSIONS | Location permission row | `:69` | n/a |
| CALIBRATION | Calibration card, `±` and reference | `:163`, `:249` | yes |
| TRIP | Reset odometer | `:75` | yes, destructive, no confirm |
| ESTIMATED SECTIONS | Section log → `/sections` | `:84` | n/a |
| ROUTE SESSIONS | Import GPX | `:271` | yes — **see D1** |
| ROUTE SESSIONS | Per session: export, delete | `:329`, `:334` | |
| DEBUG | Simulated drive | `:98` | **`kDebugMode` only** |

The debug section is inside `if (kDebugMode)`, which is a compile-time constant,
so the whole subtree is removed from a release build rather than merely hidden.
That matters: it swaps the GPS source under the entire app.

`Reset odometer` (`:75`) is a `_DangerRow` and fires immediately. It is the one
irreversible control in Settings with no confirmation step.

---

## `/sections` Section log — `section_log_screen.dart`

No interactive controls. Everything on it is a readout, and it is the screen
`docs/ROAD-TEST.md` sends the tester to.

| Field | Line | Meaning |
|---|---|---|
| §19 row 6 PASS / FAIL | `:123` | border colour follows it |
| SUSTAINED | `:132` | Hz, target ≥ 1.00 |
| FIXES | `:135` | total |
| ACCURACY | `:140` | mean, with best-worst |
| LONGEST GAP | `:145` | with count over 3 s |
| STREAM STALLS | `:152` | **must stay 0 through a tunnel** |
| NO-FIX TICKS | `:156` | watchdog heartbeats, a tunnel raises these |
| COMPASS OFFSET | `:176` | `--` until observed |
| RESIDUAL | `:182` | `--` until observed, earns TRUE at ≤ 12 |

The panel is live at 1 Hz. It was a **frozen snapshot** until C7 — it rendered
whatever the counters read when the screen opened. Two of these fields are what
the road test is supposed to report, so it was reporting the wrong numbers for
as long as it existed.

---

## `/welcome` Permission rationale — `permission_rationale_screen.dart`

One control: `CONTINUE` at `:165`, disabled while `_busy`. Shown once, gated on
the `onboarded` flag, and it explains rather than enforces — it is marked done
whether or not the user granted anything, because re-showing it would only nag.

`main()` requests no permissions at all; the root gates the eager GPS start,
because `getPositionStream` raises the system dialog itself and starting it
early would put the cold prompt on top of the screen meant to explain it.

---

## Values with no control anywhere

Worth listing because "there is no button for this" is a finding in itself.

| Value | Where it can be changed |
|---|---|
| Trip A / B to a specific number | **nowhere** — D4 |
| Compass calibration | **nowhere** — learned and revoked automatically; `HeadingCalibration.reset()` exists and has no caller |
| Map tile source | **nowhere** — hard-coded, open question with Amirali |
| Units of distance | **nowhere** — metric only; the speed unit toggle does not touch distance |
| Language / numerals | **nowhere** — no `supportedLocales` at all (`app.dart:44-49`), which is C20 and depends on Amirali's answer about Persian-Indic digits |
