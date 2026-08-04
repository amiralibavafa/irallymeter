# IRAN DEPLOYMENT CONSTRAINTS

What actually changes when this app ships to Iran rather than to the Play Store
and the App Store.

Every claim below carries a marker. **[VERIFIED]** means I ran the command, read
the file, or read the primary source and can point at it. **[SOURCED]** means it
comes from a named third party I have not been able to reproduce myself.
**[UNVERIFIED]** means it is my reasoning and nobody has checked it. Treat the
three differently — the whole point of the markers is that a plan built on
[UNVERIFIED] rows is a plan built on my guesses.

Written 2026-08-03 against branch `SA-V1` at commit `0676383`.

---

## 0. The one-paragraph version

The distribution story is survivable and largely Amirali's call. The
**engineering** story has one real problem, and it is the map: the app fetches
tiles live from `tile.openstreetmap.org`, offline support is a code comment
rather than an implementation, and the OSM Foundation **explicitly prohibits**
the pre-seeding that offline support would require. A rally computer whose map
only works where there is mobile data is a rally computer whose map does not
work on a rally. Everything else here is a smaller fix or a decision to write
down. Localisation is the second item: there is none at all, not partial.

---

## 1. Android distribution — Cafe Bazaar and Myket

### What is true today

- Google Play is not a realistic channel for Iranian users. **[SOURCED]**
- **Cafe Bazaar** supports non-Iranian developers: roughly 120 non-Iranian
  developers/publishers, contracts available, 70 % revenue share on sales and
  IAP. **[SOURCED —
  [Mobile World Live Q&A](https://www.mobileworldlive.com/apple/qa-cafe-bazaar-discusses-iran-apps-market/)]**
- **Cafe Bazaar** requires official authentication before publishing for apps
  that represent an artist, company, organisation, government office, bank,
  website, blog, event or conference. A rally club's app plausibly lands in that
  category. **[SOURCED —
  [Cafe Bazaar publish guidelines](https://developers.cafebazaar.ir/en/app-publish-guidelines/app-publish-guidelines-print/)]**
- **Myket** reports 8 M+ active users and accepts foreign developers.
  **[SOURCED]**

### What I could not verify, and it matters

`developers.cafebazaar.ir` renders its guidelines through JavaScript; fetching
the page returns only `Loading…`. **[VERIFIED — I tried it]** So I have the
summary of the rules but not the rules themselves. Specifically **[UNVERIFIED]**:

- whether Bazaar/Myket require APK or accept AAB;
- their minimum/target SDK floor and whether it tracks Play's;
- whether background location triggers an extra review step, the way Play's
  sensitive-permission declaration does;
- whether the store requires its own SDK for updates or licensing.

**Nobody should set the build configuration from this document.** Amirali has an
Iranian phone number and can read the guidelines in Persian directly; that is a
ten-minute job for him and an unresolvable one for me.

### What the build config already assumes

- `minSdk = 23` (Android 6.0), set deliberately by Amirali. **[VERIFIED —
  `android/app/build.gradle:35`]** This is the right instinct for this market and
  it is under active attack: **Flutter's Gradle migrator rewrites it to
  `flutter.minSdkVersion` (= 24) on every Android build**, silently dropping
  Android 6.0. It has been reverted twice during this audit. **[VERIFIED —
  reproduced twice, commit `8b2ef15`]**
- `applicationId = com.irallyclub.irallymeter`. **[VERIFIED —
  `android/app/build.gradle:24`]**

---

## 2. iOS — the path exists, but it is not a path you can rely on

This is worse than the Android side and deserves a decision rather than a
default.

- Iranian users are barred from the App Store and from Apple developer services
  under sanctions. **[SOURCED]**
- Third-party Iranian iOS stores (SibApp, Nassaab and others) fill the gap. A
  5.5-month academic study of three of them found 1,767 apps, of which 510 were
  Iranian-exclusive. **[SOURCED — [arXiv 2604.26343](https://arxiv.org/html/2604.26343v1)]**
- They distribute by one of two routes: **ad-hoc provisioning** (the store
  registers each user's UDID, then signs the app per user, taking up to 72 h) or
  **enterprise certificates** (one certificate pre-signs the whole catalogue).
  **[SOURCED — same study]**
- **Apple detects and revokes these accounts regularly. On revocation every app
  installed through that store stops working at once**, and users must
  re-download after the store buys a new account and re-signs.
  **[SOURCED — same study]**
- The same study found 489 apps carrying unauthorised provisioning profiles and
  180+ with piracy/hooking libraries (Cydia Substrate, iGameGod) injected.
  **[SOURCED — same study]**

### The consequence nobody should skip

Shipping iOS through these stores means **a third party re-signs your binary**,
and **the app can be killed remotely, without warning, by Apple revoking someone
else's certificate**. For a photo-sharing app that is an annoyance. For the
instrument a co-driver is reading distances off, mid-stage, it is a different
class of problem. **[UNVERIFIED — this is my judgement, not a measured claim]**

**Recommendation:** treat Android as the shipping platform and iOS as a
best-effort secondary, and say so out loud rather than discovering it late. The
iOS code should stay correct — §18.2 is now implemented properly, see §5 — but
the release plan should not depend on it.

### iOS build state

- The project builds for the iOS simulator under Xcode 15.4.
  **[VERIFIED — `✓ Built build/ios/iphonesimulator/Runner.app`, 67 s]**
- `IPHONEOS_DEPLOYMENT_TARGET = 12.0`, set deliberately. **[VERIFIED —
  `ios/Runner.xcodeproj/project.pbxproj`]** **Trap:** `flutter build ios`
  migrates the project and raises it to **13.0**, dropping iPhone 5s / 6 / 6 Plus
  — the same older-handset question as `minSdk 23`, and it also rewrites
  `AppDelegate.swift`, `Podfile`, `Runner.xcscheme` and reformats `Info.plist`,
  stripping Amirali's explanatory comment. **[VERIFIED — reproduced, then
  reverted with `git checkout -- ios/`]** Raising the target may well be the
  right call, but it is Amirali's call and it must not arrive as a side effect of
  someone running a build.

---

## 3. Firebase — absent, and it should stay absent

- There is **no Firebase dependency anywhere** in `pubspec.yaml`. **[VERIFIED]**
- Keeping it that way is not merely tidiness. Firebase Cloud Messaging requires
  Google Play Services, which is exactly what the Cafe Bazaar/Myket device
  population may not have, and Google endpoints are unreliable from Iranian
  networks. **[UNVERIFIED as to the networks — I cannot test from Iran; the Play
  Services dependency is [VERIFIED] below]**
- If crash reporting or analytics is ever wanted, it needs a non-Google backend.
  **This is a design constraint, not a preference.**

### But Play Services is already in the APK

`geolocator_android` declares
`implementation 'com.google.android.gms:play-services-location:21.2.0'`
unconditionally, and it reaches the merged manifest. **[VERIFIED —
`geolocator_android-4.6.2/android/build.gradle:44`, and 2 matches for
`com.google.android.gms` in the merged debug manifest]**

`forceLocationManager: true` (added in `[3.6]`) changes which provider serves
fixes at runtime; it does **not** remove the dependency. On a device without Play
Services the app logs
`GooglePlayServicesUtil: com.irallyclub.irallymeter requires the Google Play
Store, but it is missing` and then works normally. **[VERIFIED — observed live on
the `rally_aosp` emulator, GPS green ±5 m, distance accumulating]**

So: **a harmless warning and some dead weight in the APK, not a functional
blocker.** Worth knowing before someone panics at the logcat line.

---

## 4. Maps — this is the real problem

### What the code does today

```dart
// lib/features/map/presentation/map_screen.dart:73
urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
userAgentPackageName: 'com.irallymeter.app',
// tileProvider: FileTileProvider(), // ← enable for offline packs
```
**[VERIFIED — read the file]**

Three separate problems in four lines.

**4a. Offline is a comment, not a feature.** The map needs live internet. A rally
runs on mountain roads and through the tunnels this entire audit is about. The
one place the map is most needed is the one place it is guaranteed not to load.
**[VERIFIED that offline is unimplemented; [UNVERIFIED] as to Iranian mobile
coverage specifically, though the tunnel case is self-evident]**

**4b. The offline plan in that comment is not permitted against OSM.** The OSM
Foundation tile usage policy prohibits bulk downloading, and defines it to
include "pre-seeding large areas or multiple zoom levels in advance" and building
"tile archives for later distribution". It names the feature directly: "Download
city/country for offline use" is **not allowed** on `tile.openstreetmap.org`.
Permitted use is "normal interactive viewing by a human where the client requests
only the tiles needed for the current viewport." Violations are met with blocking
**without notice**. **[VERIFIED — [OSMF tile usage
policy](https://operations.osmfoundation.org/policies/tiles/)]**

So the TODO in the code cannot be completed as written. The tiles have to come
from somewhere else.

**4c. The User-Agent is wrong, today, in shipped code.** The policy requires "a
clear, unique User-Agent string that names your app". The code sends
`com.irallymeter.app`; the actual application ID is `com.irallyclub.irallymeter`.
**[VERIFIED — both strings read from the repo]** It identifies an app that does
not exist. This is a one-line fix and it is the difference between being
identifiable and being anonymous traffic to an operations team deciding what to
block.

### The options, ranked

| Option | Offline | API key | Iran-friendly | Notes |
|---|---|---|---|---|
| **MBTiles pack shipped/sideloaded** (`flutter_map_mbtiles`) | Full | No | Yes | Tiles must come from a source that permits redistribution — not OSMF's server. **[SOURCED — pub.dev]** |
| **`flutter_map_tile_caching`** | Cached regions | No | Partial | Region download is exactly what the OSMF policy forbids against their server. Fine against a self-hosted or licensed source. **[SOURCED]** |
| **Neshan / Map.ir SDK** | Map.ir supports side-loaded `tiles.db` in assets | Yes | Best | Iranian providers, Iranian coverage, Iranian hosting. Adds an API key and a vendor. **[SOURCED — [Map.ir Flutter SDK](https://github.com/map-ir/mapir-flutter-map-sdk)]** |
| **Self-hosted OSM tiles** | Full | No | Yes | Most work, no vendor. OSM *data* is open; it is OSMF's *server* that is rationed. |

**Recommendation:** keep `flutter_map` (it is the right widget layer and is
already in place) and change only the tile source. For an app whose users are in
Iran, a Map.ir/Neshan source with a side-loaded pack is the shortest route to a
map that works in a valley. **[UNVERIFIED — a recommendation, not a tested
result]**

This is a `SA-V2` proposal, not something to change inside a spec-compliance
branch.

---

## 5. The Play-Services location path (GAP finding F1) — CLOSED

F1 originally claimed `forceLocationManager: false` hard-breaks GPS on devices
without Play Services. **That claim was wrong and was downgraded high → medium
after live testing**: on an AOSP image with no Play Store, geolocator logs a
warning and falls back to `LocationManager` by itself, and GPS works fine.
**[VERIFIED — live, `/tmp/shots` and logcat]**

`[3.6]` has since flipped the flag to `true` anyway, for the reason SPEC-v2 §18.2
gives rather than the availability one: fused location's "smoothing and road
snapping … is helpful for navigation and **wrong for measurement**". A snapped fix
silently rewrites the distance this instrument exists to report. Verified live on
a fresh install afterwards: GPS green ±5 m, distance accumulating, no exceptions.
**[VERIFIED — `/tmp/shots/14`]**

**Still open:** §18.2 also asks us to "evaluate fused location versus the raw
location manager during testing". Only half done — I have shown raw *works*, not
that it measures *better*. That comparison needs a real drive on a real road,
which has never happened. **[VERIFIED as a gap in our own testing]**

---

## 6. Localisation — there is none, and that is a finding, not a nuance

The gap here is total, not partial:

- `lib/app.dart:36` builds `MaterialApp.router` with **no
  `localizationsDelegates`, no `supportedLocales`, and no `locale`**.
  **[VERIFIED — read the file]**
- `intl: ^0.19.0` is declared in `pubspec.yaml` and **never imported anywhere** in
  `lib/`, `test/` or `tool/`. It is an unused dependency. **[VERIFIED — grep for
  `package:intl` returns nothing]**
- No `Jalali`, `shamsi`, `persian`, `TextDirection`, `DateFormat` or
  `NumberFormat` anywhere in `lib/`. **[VERIFIED — grep]**

### Verified on the device, not by reading the widget tree

Per the audit plan, this was checked by actually flipping the locale rather than
inferring it:

```
adb shell cmd locale set-app-locales com.irallyclub.irallymeter --locales fa-IR
```

(API 36, per-app locale, no reboot needed.) Then a **fresh** `flutter run` build.
Result: the cluster renders **entirely in English, left-to-right, with Latin
digits and a Gregorian clock** — `KM/H`, `TRIP A`, `TRIP B`, `AVG SPEED`, `ODO`,
`RST A`, `19:28:56`. **[VERIFIED — `/tmp/shots/14-fresh-build-locale-fa.png`]**

### What "adding Persian" would actually mean

Not a translation pass. Three separate pieces of work:

1. **RTL layout.** Once `Directionality` flips, every `Row`, `Padding` and
   alignment in the cluster mirrors. The dashboard is a fixed non-scrolling
   instrument panel that **already overflows by 70 px in portrait** and by 137 px
   in Estimation Mode. **[VERIFIED — live banner]** RTL will not politely leave
   that alone.
2. **Persian-Indic numerals (۰۱۲۳۴۵۶۷۸۹).** This one needs a decision, not a
   library. Rally road books and tripmeters are conventionally read in Latin
   digits, and the digits here are the product. **Ask Amirali whether Iranian
   rally crews want Persian digits on the odometer at all** — it is entirely
   possible the correct answer is "translate the labels, never the numbers".
   **[UNVERIFIED — a real question, not a rhetorical one]**
3. **Jalali dates.** Only matters where a date is displayed. Cheap once `intl`
   is actually wired up, and `shamsi`/`persian_datetime_picker` exist.
   **[SOURCED]**

**Recommendation:** this is a `SA-V2` item and it should be scoped by Amirali,
who knows the users. It is also a good argument for fixing the portrait overflow
first — RTL on top of an already-overflowing layout is two bugs interacting.

---

## 7. What to do next, in order

1. **Fix the OSM User-Agent.** One line, currently wrong in shipped code, and it
   is a policy violation today. `SA-V2`.
2. **Decide the tile source.** Nothing about offline maps can be built until this
   is settled, and the current TODO points at a route the OSMF forbids. Amirali.
3. **Read the Cafe Bazaar guidelines in Persian** and fill in §1's `[UNVERIFIED]`
   rows before anyone touches the build config. Amirali.
4. **Decide the iOS posture** — secondary platform, or accept certificate
   revocation as an operating risk. Amirali and Saam.
5. **Scope localisation**, starting with the Persian-digits question, which is a
   product decision rather than an engineering one. Amirali.

Items 2–5 are all Amirali's, and that is the honest outcome of this phase: the
Iran constraints are mostly decisions to be made by the person who knows the
market, and the job of this document is to make sure none of them get made by
accident.
