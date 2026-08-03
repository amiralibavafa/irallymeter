# BASELINE — untouched repo, before any change

Captured 2026-08-03 against `main` @ `c151ca2` ("Initial commit: iRallyMeter rally
co-driver trip computer", amir, 2026-08-03), the only commit and only branch in the
repository.

**Purpose:** anything recorded here as failing or skipped is PRE-EXISTING. It was not
caused by this audit, and it must never be "fixed" by weakening an assertion. If a later
change makes one of these green, that is a real fix and gets called out as one.

---

## Toolchain at time of capture

| Component | Version | State |
|---|---|---|
| Flutter | 3.44.8 stable (rev `058e0af2c2`) | ✓ |
| Dart | 3.12.2 | ✓ (pubspec requires `^3.6.1`) |
| DevTools | 2.57.0 | ✓ |
| CocoaPods | 1.17.0 | ✓ |
| Xcode | 14.3 (build 14E222b) | ✗ **Flutter requires Xcode 15 or higher** |
| Android SDK | not located | ✗ cmdline-tools installed, SDK not yet provisioned |
| macOS | 14.4 (23E214), darwin-arm64 | — |
| Devices available | macOS desktop, Chrome web | iOS simulator blocked by Xcode |

The Flutter SDK lives at `/opt/homebrew/share/flutter`. A prior partial `brew install
--cask flutter` had left `/opt/homebrew/bin/flutter` and `/opt/homebrew/bin/dart` as
dangling symlinks into a purged Caskroom path; both were repointed at the real SDK. The
cask itself still fails to install (`mv: cannot overwrite non-directory
.../Caskroom/flutter/3.44.8/flutter`) and was not used.

---

## `flutter analyze` — 2 issues

Not clean, but nothing that blocks. Both pre-existing.

| Severity | Location | Issue |
|---|---|---|
| info | `lib/features/settings/presentation/settings_screen.dart:295:9` | `activeColor` is deprecated after v3.31.0-2.0.pre; use `activeThumbColor` (`deprecated_member_use`) |
| warning | `test/distance_speed_test.dart:263:23` | optional parameter `stored` is never given a value (`unused_element_parameter`) |

Both are artifacts of running a newer Flutter (3.44.8) than the one the repo was authored
against — neither is a logic defect.

## `flutter test` — 115 passed, 0 failed, 1 skipped

All green. Full-suite run: `00:09 +115 ~1: All tests passed!`

| File | Passed | Skipped | Failed |
|---|---|---|---|
| `test/average_speed_test.dart` | 15 | 0 | 0 |
| `test/dashboard_layout_test.dart` | 4 | **1** | 0 |
| `test/distance_speed_test.dart` | 20 | 0 | 0 |
| `test/gps_system_test.dart` | 20 | 0 | 0 |
| `test/tunnel_scenarios_test.dart` | 18 | 0 | 0 |
| `test/tunnel_system_test.dart` | 28 | 0 | 0 |
| `test/widget_test.dart` | 10 | 0 | 0 |
| **Total** | **115** | **1** | **0** |

### The one skipped test — pre-existing, deliberate, documented

`test/dashboard_layout_test.dart:85` — **`DASHBOARD · layout 02 · portrait renders
without overflow`**, `skip: true`.

The author's own comment records why: the top bar is over-subscribed on a narrow portrait
screen. Clock (~88 px) + status badge + five 48 px nav targets (240 px) exceed a 465 px
width. Measured against a build with the tunnel feature removed entirely, **portrait
already overflowed by ~142 px**, so it is not tunnel-related. Making the status badge
`Flexible` brought it to ~34 px; closing the rest means shrinking glove-sized touch
targets, which the author explicitly declined to trade away on a rally tool.

Landscape (tests 01, 03, 04) is the co-driver configuration the cluster is designed
around and is held strictly overflow-free.

**Consequence for this audit:** this is a genuine open UI defect, not test debt. It
carries into Phase 4 as a real finding — it collides directly with the 44×44 pt
touch-target requirement, since the two constraints are what conflict. It is NOT in scope
for Phase 3 and the skip stays until its owner decides the trade.

---

## Repository state notes

- **`pubspec.lock` drifts on `flutter pub get`.** Resolving under Dart 3.12.2 changed 31
  lines (15 dependencies bumped within their existing constraints) versus the committed
  lock. 58 packages have newer versions held back by constraints. The lock is modified in
  the working tree as a direct consequence of running the suite at all — it is not an
  edit made by this audit, and it is called out here so it is not mistaken for one later.
- `docs/` is newly added by this audit (SPEC-v1.md, SPEC-v2.md).
- No `.github/`, no CI configuration, no `AGENTS.md` at capture time.

## Commands that reproduce this baseline

```sh
cd "/Users/saamsani/0xDEAD/Saam&Amirali/irallymeter"
flutter pub get
flutter analyze                    # expect 2 issues
flutter test --reporter expanded   # expect +115 ~1, all passed
```
