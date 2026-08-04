# SECURITY REVIEW — permissions and location-data handling

Phase 5, run against `SA-V2`. Scope: what the app can learn about the user,
where it goes, and what it asks for.

## Verdict

**Clean. The one thing to fix is now FIXED; two remain worth being aware of.** There is no telemetry,
no analytics SDK, no crash reporter, and no account. Location never leaves the
device except implicitly, via map tile requests.

---

## S1 · `ACCESS_BACKGROUND_LOCATION` declared but never requested — **FIXED**

`AndroidManifest.xml` declares it. Nothing in `lib/` ever requests it:
`Permission.locationAlways` appears nowhere, and `ensurePermission()` only calls
`Geolocator.requestPermission()`, which asks for foreground location.

Two consequences:

* **Store review flag.** Background location is one of the most scrutinised
  permissions there is. Declaring it obliges you to justify it, and a
  declaration you never exercise is the worst of both worlds — the review cost
  without the capability.
* **It does not do what the manifest implies.** Background tracking currently
  works through the **foreground service**, not through this permission.

**FIXED 2026-08-04: removed from the manifest.** The foreground service already
delivers screen-off tracking, which is what a rally actually needs.

Safe by construction rather than by argument: a permission that is declared but
never requested is never granted, and an ungranted permission confers no
capability — so removing it cannot change runtime behaviour. What it does remove
is the obligation to justify one of the most heavily scrutinised permissions on
either store. Re-add it ONLY together with a real runtime request and its own
rationale screen.

**Verified after the change:** release APK builds, installs, and streams
position normally (`GPS ±5m`). Screen-off tracking over a long drive is
`docs/ROAD-TEST.md` item 9 and remains unverified on hardware — as it was before
this change, for the same reason: the foreground service, not this permission,
is what makes it work.

## S2 · Map tiles disclose position to a third party — BE AWARE

The only network egress in `lib/` is
`https://tile.openstreetmap.org/{z}/{x}/{y}.png`. Requesting tiles for where you
are tells the tile server where you are. That is inherent to any online map, not
a defect, but it is worth stating plainly because:

* it is the **only** way location leaves the device, and
* it disappears entirely once offline tiles land (`docs/IRAN-CONSTRAINTS.md` §4),
  which turns a privacy consideration into a non-issue as a side effect.

`gpx_codec.dart` also contains `http://www.topografix.com/GPX/1/1` — that is an
XML namespace identifier, not a request. No traffic.

## S3 · Route logs are stored unencrypted — ACCEPTABLE, stated

Hive box `irallymeter` persists trip/odometer/calibration/settings, the last
known lat-lng, and full route sessions as JSON point lists. Unencrypted, in the
app's private storage.

Appropriate for a trip computer: it is the user's own track on their own device,
and encryption would add key management for no threat model that applies here.
Worth knowing before anyone adds anything more sensitive to that box.

---

## What is NOT present, and should stay that way

No Firebase, no Crashlytics, no Sentry, no analytics of any kind — grep of
`pubspec.yaml` returns zero. No login, no account, no server. For an app
shipping to Iran that is a feature, not an omission
(`docs/IRAN-CONSTRAINTS.md` §3).
