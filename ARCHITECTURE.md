# ARCHITECTURE.md — Phase 0 recon

**Read-only scan of iRallyMeter as it exists on `SA-V3` @ `8af9bcb`, 2026-08-30.**
Written to satisfy `SPEC.md` §2. No code was changed to produce it.

Method: `repomix` pack (166 files / 246,953 tokens after excluding GPS fixtures, which
are 96 % of the raw pack), three parallel read-only scans of the Dart, native and
config surfaces, plus direct verification of the claims that change the plan.
Every claim below cites `file:line` or the command that produced it.

---

## 0. The one-paragraph answer

iRallyMeter is a **single-process, offline-first Flutter app with no backend, no
network client, no accounts and no secure storage**. The native layers are empty
shells. Everything this brief asks for is greenfield. The risk is therefore *not*
"don't break the existing integration" — there is none to break. The risk is that the
new layer reaches into a measurement engine that is 10,426 lines of carefully
tuned, 1:1 test-covered Dart, and into an onboarding screen that currently promises
users the opposite of what this brief builds.

---

## 1. Module map

### `lib/` — 73 Dart files, 10,426 lines, feature-first

| Path | What it is |
|---|---|
| `main.dart` | Wakelock, immersive chrome, `StorageService.init()`, then `runApp` inside one `ProviderScope` with a single override (`main.dart:93-95`). |
| `app.dart` | Root `ConsumerWidget`, `MaterialApp.router`. **`app.dart:29-42` eagerly starts the GPS→distance→trip→average chain, gated on `onboardedProvider`.** |
| `core/constants/app_constants.dart` | 441 lines, every tuning constant. Read by every feature. |
| `core/di/providers.dart` | The DI seam; `storageProvider` throws unless overridden (`:8-10`). |
| `core/router/app_router.dart` | `go_router`, 6 flat routes (`:30-39`). |
| `core/storage/storage_service.dart` | The only persistence. One Hive box `'irallymeter'` (`:10,15`), 14 keys (`:45-74`). |
| `core/theme/`, `core/utils/`, `core/widgets/` | Day/night palette, angle smoothing, formatters, geo math, clock. |
| `features/gps/` | 8 files. Ingest, filtering, health, stall detection. |
| `features/distance/` | 14 files. **The engine.** Integration, dead reckoning, reconciliation. |
| `features/trip/` | Counters, calibration, persistence. |
| `features/compass/` | Tilt-compensated fusion, learned true-north offset. |
| `features/dashboard/` | 7 widgets — the instrument cluster. |
| `features/average_speed/`, `stage_timer/`, `route_log/`, `map/`, `replay/`, `settings/`, `onboarding/` | Supporting features. |

### Other trees

- `test/` — 45 files, 10,315 lines. **Test-to-source is 1:1 by line count.**
- `test/fixtures/` — 9 `.jsonl` GPS traces, `linguist-generated -diff`, produced by `tool/generate_fixtures.dart`.
- `integration_test/app_flows_test.dart` — 295 lines, 5 tests, drives the real app on a device.
- `scripts/run-integration.sh` — the only script; retries `adb pm grant` for 120 s because a reinstall drops permissions and the resulting system dialog hangs the run.
- `docs/` — 25 files. `SPEC-v2.md` governs measurement; `QA-REPORT.md` supersedes `AUDIT-REPORT.md`.

---

## 2. Dependency graph (`pubspec.yaml`)

```
irallymeter
├── state/nav   flutter_riverpod ^2.6.1 · go_router ^14.6.2
├── gps         geolocator ^13.0.2 · sensors_plus ^6.1.1 · permission_handler ^11.3.1
├── maps        flutter_map ^7.0.2 · latlong2 ^0.9.1
├── storage     hive ^2.2.3 · hive_flutter ^1.1.0 · path_provider ^2.1.5
├── platform    wakelock_plus ^1.2.8 · share_plus ^10.1.3 · file_picker ^8.1.6
└── ui          cupertino_icons ^1.0.8
dev: flutter_test · integration_test · flutter_lints ^5.0.0
```

**Nothing for auth, HTTP, payments or secure storage.** `http 1.1.0` and `crypto` exist
in `pubspec.lock` as **transitive** dependencies only; no file in `lib/` imports either.
`intl` was deliberately removed on `SA-V2` and must come back before any Persian work.

---

## 3. Does a backend exist? **No.**

No `backend/`, `server/`, `api/`, `functions/` or `prisma/` directory. No Node project,
no runtime, no framework. `git grep -i` for `neon`, `postgres`, `postgresql`, `infobip`,
`zarinpal`, `dotenv`, `supabase`, `package:http`, `package:dio`, `HttpClient`,
`fromEnvironment`, `dart-define` and `payment` returns **0 files** for every term. The
same command returns **20 files** for the control term `geolocator`, so the search
method is proven, not assumed.

There is no `.env`, no `.env.example`, and `.gitignore` has no `.env` entry because one
has never existed.

---

## 4. Existing Flutter auth / payment / HTTP architecture

**None of the three exists.**

- **HTTP:** the only outbound request in the entire app is
  `map_screen.dart:104` — `https://tile.openstreetmap.org/{z}/{x}/{y}.png`, fetched by
  `flutter_map`'s default `NetworkTileProvider`. There is no client, no base URL, no
  interceptor, no retry, no error model.
- **Auth / user / entitlement:** a grep for `login|oauth|jwt|password|credential|
  entitlement|purchase|paywall|billing|account` returns exactly one hit, and it is a
  promise to the user — see §8.1 below.
- **Storage:** Hive, **unencrypted**. `openBox` takes no `encryptionCipher`
  (`storage_service.dart:15`); a grep for `secure_storage|HiveAesCipher|Keychain|
  EncryptedSharedPreferences` across `lib/`, `android/` and `ios/` returns zero.

---

## 5. Native integrations and platform channels

**There are no hand-written platform channels on either platform.** The only
`MethodChannel` references anywhere are Dart-side *test mocks* of third-party plugin
channels (`plugins.flutter.io/path_provider`, `flutter.baseflow.com/permissions/methods`).
No Pigeon, no `pigeons/` directory.

| | Android | iOS |
|---|---|---|
| Native source | `MainActivity.kt` — 5 lines, empty body | `AppDelegate.swift` — 16 lines, plugin registration only |
| Generated | `GeneratedPluginRegistrant.java`, 10 plugins | `GeneratedPluginRegistrant.m`, 9 plugins |
| Package / bundle id | `com.irallyclub.irallymeter` | `com.irallyclub.irallymeter` |
| SDK floor | **minSdk 24 effective** (`build.gradle:118` hard-overrides after the `android{}` block) | **`IPHONEOS_DEPLOYMENT_TARGET = 13.0`** in all three configs (`project.pbxproj:476,605,656`) |
| Signing | Real keystore via `android/key.properties` (gitignored, present on this machine) | `CODE_SIGN_STYLE = Automatic`, **no `DEVELOPMENT_TEAM`** |
| Network | **`INTERNET` permission present** (`AndroidManifest.xml:24`) | No ATS overrides; HTTPS by default |
| Deep links | **NONE** | **NONE** |

---

## 6. Env / config / Neon

Nothing. The only configuration surface is `app_constants.dart` (441 lines of
`static const` tuning knobs — no secrets, no URLs) and `analysis_options.yaml` (stock
template, zero custom rules). **There is no existing Neon configuration of any kind.**

---

## 7. What is well designed and MUST NOT be touched

These files are the product. A later phase may read them; it may not modify them.

**GPS ingest** `gps/data/geolocator_gps_service.dart` (371 L) · `gps/domain/gps_repository.dart` · `gps_sample.dart` · `gps_health_stats.dart` · `gps/presentation/providers/gps_providers.dart` (420 L)
**Speed filtering** `gps/domain/gps_state.dart` — `SpeedFilter` at `:105`, time-based EMA
**Distance integration** `distance/domain/distance_engine.dart` (706 L) · `gps_distance_source.dart` · `distance_delta.dart` · `distance_engine_state.dart` · `distance/presentation/providers/distance_providers.dart` · `trip/presentation/providers/trip_providers.dart` · `core/utils/geo_math.dart` · `trip/domain/calibration.dart`
**Tunnel / dead reckoning** `gps/domain/gps_stall_detector.dart` · `distance/domain/sensor_distance_source.dart` · `longitudinal_axis_estimator.dart` · `distance_reconciler.dart` · `estimated_section.dart` · `measurement_status.dart` · `motion_sample.dart` · `motion_repository.dart` · `distance/data/sensors_motion_service.dart`
**Trip counters** `trip/domain/trip_state.dart` · `trip/data/trip_repository.dart`
**Compass** `compass/data/compass_service.dart` · `compass/domain/heading_calibration.dart` · `compass/data/heading_calibration_repository.dart` · `compass/presentation/providers/compass_providers.dart` · `core/utils/angle_smoother.dart`
**Crown jewel by dependency** `core/constants/app_constants.dart` — every file above reads it
**The regression net** `replay/` and `tool/generate_fixtures.dart` — changing either silently weakens verification of everything above

---

## 8. Findings that change the plan

Ordered by how much they change it.

### 8.1 The app currently promises users there is no account and no server

`lib/features/onboarding/permission_rationale_screen.dart:179-184`, verbatim:

> **WHERE IT GOES** — "Nowhere. There is no account, no analytics and no server.
> Trips stay on this phone. The only thing the app ever downloads is map tiles, and
> only while the map screen is open."

This brief adds an account, a server, and (per `SPEC.md` §6.1) eight analytics events.
**Three of that paragraph's four claims become false on the day this ships.** The copy
must change in the same release; shipping it unchanged means the app lies to its users
on the first screen they see.

Good news: the two tests that touch it (`test/onboarding_test.dart:110,145`) assert only
`find.textContaining('WHERE IT GOES')` — the heading, not the body. **The body can be
rewritten without weakening any assertion.**

### 8.2 CONFIRMED BY EXPERIMENT — a fresh clone cannot build *at all*, not even debug

`android/app/build.gradle:83-87` throws `GradleException` when `key.properties` is
missing. The comment at `:80-82` claims "developers who do not have it can still use
debug builds". **That is false.** The `throw` sits in a `buildTypes { release { … } }`
Groovy configuration closure, which Gradle evaluates on *every* invocation regardless of
the requested task.

Measured, with a control:

| run | `key.properties` | `./gradlew :app:assembleDebug --dry-run` |
|---|---|---|
| control | present | **exit 0** |
| test | hidden | **exit 1** — `Release build requires android/key.properties` |

`key.properties` was restored and its sha256 verified byte-identical afterwards.

**This blocks Amirali specifically** — he owns the repo and does not have the keystore.
It is a defect introduced during this engagement and it is not part of this brief, but
it must be fixed before he can build anything, including this feature. The fix is to
move the check out of the configuration closure so it fires only when a release variant
is actually assembled.

### 8.3 "Offline maps" do not exist yet

`SPEC.md` §4.4 lists offline maps among the things that "MUST keep working with zero
connectivity". They do not work offline today: `map_screen.dart:104` fetches live tiles
and `tileProvider: FileTileProvider()` is commented out. The comment at `:112-127`
records that with data off, no error callback ever fires. This is a pre-existing open
question (tile source undecided; the OSMF policy prohibits the pre-seeding the TODO
plans), **not something this brief breaks** — but §4.4 should be read as "must not
regress", not "must keep working".

### 8.4 A payment return URL has nowhere to land

Neither platform declares a custom scheme, App Link or Universal Link. Proof:
`grep -rniE "CFBundleURLTypes|android:scheme|BROWSABLE|autoVerify|applinks"
android ios` returns nothing outside macOS project scaffolding, and
`find ios android -name "*.entitlements"` returns none.

This is genuine new native work on both platforms and it is on the critical path for
ZarinPal. Two facts that shape it: `MainActivity` is `launchMode="singleTop"` with
`taskAffinity=""` (`AndroidManifest.xml:35-36`), so a callback arrives in `onNewIntent`,
not a fresh activity; and `AppDelegate.swift` overrides neither
`application(_:open:options:)` nor `continue userActivity`, and uses the newer
`didInitializeImplicitFlutterEngine` hook (`:13`).

### 8.5 A login gate needs two coupled changes, and one fights a documented decision

`app_router.dart:48` reads the onboarding flag with `ref.read`, **not** `ref.watch`, and
the comment at `:44-46` says why: a rebuilt router "would reset the navigation stack
under the driver". Making auth reactive fights that decision deliberately.

And a gate placed only in the router is not a gate: `app.dart:29` starts the GPS and
distance engine on its own condition, so the measurement stack would spin up behind the
login screen. **Both sites must change together.**

### 8.6 ZarinPal amount unit — answered from the vendor's own docs

`SPEC.md` §5.6 requires this be verified rather than assumed. From ZarinPal's
documentation via context7:

- `POST https://payment.zarinpal.com/pg/v4/payment/verify.json` — "**amount** (Integer) —
  Required — The transaction amount **in Rials**."
- `POST /pg/v4/payment/request.json` accepts an **optional `currency`** field, example
  value `"IRT"` (Toman).

⇒ **The default unit is RIAL. 400,000 Toman = 4,000,000 Rial.** Getting this wrong is a
10× error in either direction. The `currency` field and the resolved unit must both be
stored on the `payments` row, and `verify` must be called with the *same* amount as
`request`.

Also settled, and directly relevant to test §7.17: **`code` 100 means verified now;
`code` 101 means "already verified"**. That is ZarinPal's own duplicate-callback signal
and it must be handled as success-without-re-activation, alongside the
`UNIQUE (gateway, authority)` constraint.

⚠ **Do not use ZarinPal's tokenized `InvoiceAdd` GraphQL API**: it requires `payer_name`
and `payer_mobile` as non-null, which violates `SPEC.md` §5.1 "collect NOTHING beyond
phone". The classic `pg/v4` REST pair is the compliant path.

### 8.7 `AGENTS.md` exists already, and its rules are worth more than its numbers

`SPEC.md` §8.1 says "Write `AGENTS.md` at repo root". **It is already there, 156 lines**,
and it carries the ownership boundary, the never-touch-`main` rule, the deliberate-skip
rule, five domain invariants and two widget-test traps. Those must survive.

Its *numbers* are stale and should be corrected: it says 310 pass (**measured today:
433 pass / 1 skip / 0 fail**), 3,592 lines of `lib/` (**measured: 10,426**), lists only
`SA-V1` and `SA-V2` (**`SA-V3` and now `SA-V4` exist**), and claims `minSdk = 23` and
`IPHONEOS_DEPLOYMENT_TARGET = 12.0` as deliberate floors when the real values are **24**
and **13.0**. ⇒ **Amend, never replace.**

---

## 9. Baseline captured for this phase

| Measure | Value | How |
|---|---|---|
| Tests | **433 pass / 1 skip / 0 fail** | `flutter test`, run 2026-08-30 |
| The 1 skip | `road_scenarios_test` 12, urban canyon −12.50 % | deliberate; `AGENTS.md:61-75` forbids "fixing" it |
| `lib/` | 73 files / 10,426 lines | `find` + `wc` |
| `test/` (excl. fixtures) | 45 files / 10,315 lines | same |
| Branch | `SA-V4`, cut from `SA-V3` `8af9bcb` | `git rev-parse` |
| `origin/main` | `c151ca2`, single commit, never advanced | `git rev-list --left-right --count main...SA-V3` = `0 115` |
| Toolchain | Flutter 3.44.8 / Dart 3.12.2, Node v22.23.2, `prisma` CLI present | `flutter --version`, `node --version` |
| CI | none | `find` for `.github`, `.gitlab*`, `.circleci`, `.buildkite` → empty |

---

## 10. Credentials — none of them exist yet

Every one of the ten env vars named in `SPEC.md` §4.5 is **unset on this machine**,
checked by name and presence only:

`DATABASE_URL` · `INFOBIP_API_KEY` · `INFOBIP_BASE_URL` · `INFOBIP_2FA_APPLICATION_ID` ·
`INFOBIP_2FA_MESSAGE_ID` · `ZARINPAL_MERCHANT_ID` · `ZARINPAL_CALLBACK_URL` ·
`ZARINPAL_SANDBOX` · `JWT_ACCESS_SECRET` · `JWT_REFRESH_SECRET` — all **not set**.

`neonctl` and `psql` are not installed. ⇒ **Infobip and ZarinPal cannot be verified
against the live services in this engagement, and per `SPEC.md` §4.5 they will be
reported as UNVERIFIED rather than claimed working.** Everything can still be built and
tested against mocks at the HTTP boundary (`SPEC.md` §7).
