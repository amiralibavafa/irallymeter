# PHASE 4 — UI AND CODEBASE AUDIT

**Nothing here is implemented. Nothing here should be implemented without
Amirali or Saam picking it.** Approved items go on a new branch `SA-V2`; this
document exists so the choice is made deliberately rather than by whoever
touches the file next.

Written 2026-08-03 against `SA-V1` at `fdc2efd`. Evidence is from the live app on
the `rally_aosp` emulator (Android 16, no Play Services) plus the codebase, not
from reading the widget tree alone.

---

## The three-line version

The **map** is the biggest risk and it is not a UI polish item: it needs network
in exactly the places a rally does not have network, and the offline route the
code plans is prohibited by the tile provider. The biggest **improvement per unit
of effort** is `P1` — ten lines that remove a class of first-launch hang.
**Go/no-go: the measurement engine is sound and this is shippable to a test
crew, but not to a paying entrant until `P2` and `P6` are decided.**

---

## Ranked by impact per unit of effort

### P1 · `main()` can wedge the app on the splash screen — HIGH, ~10 lines

`lib/main.dart:33-40` awaits two permission requests **before** `runApp`, with no
`try`/`catch`:

```dart
await GeolocatorGpsService().ensurePermission();
if (await Permission.notification.isDenied) {
  await Permission.notification.request();
}
runApp(...);
```

If either throws, `runApp` is never reached and the Flutter splash stays up
**forever**. There is no timeout and no error path.

**This is not hypothetical.** On the first-ever run of this app during Phase 0 it
threw exactly that:
`PlatformException(PermissionHandler.PermissionManager, 'A request for
permissions is already running')` — two permission requests overlapping — and the
app hung on the splash. It booted normally on restart once permissions were
pre-granted, which is what identified it as the first-run path.

**Honest correction to the earlier severity.** I re-tested today with a genuine
`adb uninstall` and a clean reinstall of the current branch, and **it did not
reproduce**: both prompts appeared in sequence and the cluster booted with all
counters at zero (`/tmp/shots/15`, `16`, `17`), with no exception in logcat.
`main.dart` has not been touched in this audit, so the code path is identical to
the one that failed. That makes F5 an **intermittent race that did not fire on
this attempt**, not a fixed bug — and the structural hazard (unguarded awaits
gating `runApp`) is certain regardless of how often the race lands.

**Proposed fix:** move both requests to after `runApp` — or, minimally, wrap them
in `try`/`catch` so a permission failure can never gate the first frame. The
status bar already surfaces GPS-lost, so the UI degrades honestly on its own.

**Recommendation: do this one.** It is small, it is contained, and the failure it
removes is the worst kind — a brand-new user whose app never starts.

---

### P2 · The portrait layout overflows in shipped builds — HIGH, needs a decision

`OVERFLOWED BY 70 PIXELS` is visible on the running app at 1080×2400. It is not
static:

| State | Overflow |
|---|---|
| `GPS ±5m` | 70 px |
| `GPS SYNC` | 79 px |
| Estimation Mode (`TUNNEL · EST 0.00`) | **137 px** |

**It scales with the status text**, so the worst case is the state where the app
is least sure of itself and most needs to say so. The cluster is a fixed,
non-scrolling instrument panel, so an overflow means a co-driver cannot read a
number mid-stage.

Amirali already knew: `dashboard_layout_test` 02 is skipped with his own note
recording ~142 px before the tunnel feature existed. The top bar is
over-subscribed — clock (~88 px) + status badge + five 48 px nav targets (240 px)
against a 465 px logical width.

**This is a design decision, not a bug fix.** Closing it means shrinking
glove-sized touch targets, dropping something from the top bar, or accepting that
portrait is unsupported. All three are Amirali's call. Landscape — the co-driver
configuration the cluster is designed around — is held strictly overflow-free by
tests 01/03.

**Recommendation: decide, don't drift.** If portrait is unsupported, lock the app
to landscape in `main.dart` and delete the skipped test. That is honest and free.
If portrait is supported, it needs real layout work and RTL (see `P7`) makes it
worse.

---

### P3 · Both permission prompts are cold — MEDIUM, store-rejection risk

Verified live on a first install: the user sees a **blank grey screen** and then
the system location dialog, with no in-app explanation first
(`/tmp/shots/15`), followed immediately by the notification dialog
(`/tmp/shots/16`).

Background location with no rationale is a well-known review flag, and the
notification prompt is unexplained — the user has no idea it exists to keep the
GPS foreground service alive. A user who taps DON'T ALLOW on notifications
silently degrades their own tracking.

**Proposed fix:** a one-screen rationale before the first request, explaining
that location is the product and the notification is what keeps it running with
the screen off. Pairs naturally with `P1`, since both live in the launch path.

---

### P4 · The app identifies itself as "irallymeter" — LOW, one line

System permission dialogs read *"Allow **irallymeter** to access this device's
location?"* — lowercase, unbranded (`/tmp/shots/15`, `16`). The Android label
does not match the product name used everywhere else. One string in
`AndroidManifest.xml`.

---

### P5 · The OpenStreetMap User-Agent names an app that does not exist — LOW, one line, **wrong today**

`map_screen.dart:74` sends `userAgentPackageName: 'com.irallymeter.app'`. The
real application ID is `com.irallyclub.irallymeter`. The OSMF tile usage policy
requires "a clear, unique User-Agent string that names your app".

Full reasoning in `docs/IRAN-CONSTRAINTS.md` §4c. **This is a policy violation in
shipped code and costs one line to fix.**

---

### P6 · Offline maps are unimplemented, and the planned route is prohibited — HIGH, blocked on a decision

`map_screen.dart:73` fetches tiles live from `tile.openstreetmap.org`, and the
offline plan is a commented-out `FileTileProvider()`. The OSMF policy explicitly
prohibits the pre-seeding that plan requires and names "Download city/country for
offline use" as not allowed.

A rally computer's map that needs mobile data does not work on a rally. See
`docs/IRAN-CONSTRAINTS.md` §4 for the ranked options.

**Recommendation: keep `flutter_map`, change only the tile source.** Blocked on
Amirali choosing a provider.

---

### P7 · There is no localisation at all — MEDIUM, larger than it looks

`MaterialApp.router` has no `localizationsDelegates`, no `supportedLocales`, no
`locale`. Verified on device with the per-app locale set to `fa-IR`: the cluster
renders entirely in English, LTR, Latin digits (`/tmp/shots/14`).

Three separate pieces of work, not a translation pass. Full breakdown in
`docs/IRAN-CONSTRAINTS.md` §6, **including one question only Amirali can answer:
do Iranian rally crews want Persian-Indic digits on the odometer at all, or
translated labels over Latin numbers?**

Do `P2` first — RTL on an already-overflowing layout is two bugs interacting.

---

### P8 · `DistanceEngineController` hard-codes the wall clock — MEDIUM, unblocks a test

`distance_providers.dart` drives `_engine.tick(DateTime.now())` from a
`Timer.periodic`. `tester.pump(Duration)` advances only the fake async clock, so
**no widget test can ever put the engine into Estimation Mode.**

That is how `dashboard_layout_test` 05 came to pass **vacuously**: its
`find.textContaining('TUNNEL')` was matching the manual tunnel *button* label,
not the status bar. Deleting the button in `[3.4b]` exposed it, and it is now
skipped with that explanation.

The engine itself takes `now` as a parameter and is fully testable; it is the
*provider* that hard-codes the clock. Injecting a clock there restores real
coverage of the top bar in its worst-overflow state — which is exactly `P2`'s
worst case, so these two pay each other back.

---

### P9 · Every direct dependency is behind, several by major versions — MEDIUM, do it deliberately

| Package | Current | Latest |
|---|---|---|
| `geolocator` | 13.0.4 | **14.0.3** |
| `go_router` | 14.8.1 | **17.3.0** |
| `flutter_map` | 7.0.2 | **8.3.1** |
| `flutter_riverpod` | 2.6.1 | **3.4.2** |
| `permission_handler` | 11.4.0 | **13.0.0** |
| `sensors_plus` | 6.1.2 | **7.1.0** |
| `share_plus` | 10.1.4 | **13.3.0** |
| `file_picker` | 8.3.7 | 11.0.3 |
| `intl` | 0.19.0 | 0.20.3 |
| `latlong2` | 0.9.1 | 0.10.1 |
| `flutter_lints` | 5.0.0 | 6.0.0 |

`geolocator`, `flutter_map` and `flutter_riverpod` are the load-bearing ones and
all three have crossed a major version. **Do not bundle this with anything
else** — a Riverpod 2→3 migration touches every provider in the app, and doing it
inside a branch that also changes measurement behaviour would make a regression
impossible to attribute.

**Recommendation: its own branch, its own review, after `SA-V1` merges.**

---

### P10 · `intl` is declared and never imported — LOW, one line

`intl: ^0.19.0` is in `pubspec.yaml` and appears nowhere in `lib/`, `test/` or
`tool/`. Either delete it or use it when `P7` lands. Right now it is a dependency
that ships for nothing.

---

### P11 · §15.3 has no user-facing surface — MEDIUM, spec-adjacent

`[3.4c]` implemented the automatic section log: every estimated section now
records its start, end, duration, estimated distance, held speed and correction.
**That data currently has no screen.** SPEC-v2 §15.3 says the record "gives the
user the same information the manual buttons would have provided" — the manual UI
it replaces was deleted in `[3.4b]`, so there is a real gap.

Deliberately left for this phase: the engine half is spec compliance and belongs
in `SA-V1`; the screen is a design decision and belongs here, with Amirali
picking what it looks like and where it lives.

---

### P12 · Accepted, not defects — recorded so nobody "fixes" them

- **Trip persistence flushes at most every 5 s** (`tripPersistInterval`), plus an
  immediate write on user edits and a flush on dispose. A crash or force-kill
  loses ≤5 s of distance — ~139 m at 100 km/h. That is a deliberate trade against
  churning flash on every fix, and the right one.
- **`play-services-location` ships in the APK regardless of
  `forceLocationManager`.** Dead weight and a harmless logcat warning, not a
  functional blocker. Verified live. See `docs/IRAN-CONSTRAINTS.md` §3.
- **`ODO` formats as `0 m` / `2.31 km` while `TRIP A` is always `0.00 KM`.**
  Different readouts, deliberately different precision. Cosmetic at most.

---

## What I did not test, and will not claim

- **No road test.** Every accuracy number in this audit comes from generated
  fixtures where ground truth is exact by construction, or from an emulator.
  §20.2 asks for a measured route, a route with real tunnels, and a tight curved
  road; **none of that has happened.**
- **`tunnel_2km.jsonl` feeds zero accelerometer input**, so §12.2's ±25 %
  refinement has never run inside a full tunnel replay — only in isolated unit
  tests.
- **No battery or thermal profiling.** A DevTools session over a sustained
  screen-on GPS run is the right way to answer it, and it needs a real device
  rather than an emulator to mean anything.
- **No iOS runtime testing.** The project builds for the simulator; nobody has
  run it there.

---

## Recommendation

Take **`P1`, `P4`, `P5`, `P10`** as one small `SA-V2` branch — four contained
fixes, roughly twenty lines total, one of which is a live policy violation and
one of which removes a first-launch hang.

Then decide **`P2`** (is portrait supported?) and **`P6`** (which tile source?),
because everything else in the UI backlog queues behind those two answers.

Leave **`P9`** until `SA-V1` is merged.
