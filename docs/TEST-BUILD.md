# TEST BUILD — what to hand a tester, and what a clean start looks like

For giving the app to Amirali's dad (and for Saam's own drive). Written after a
release APK was built and installed for the first time, 2026-08-04.

---

## Build it in RELEASE, not debug. This is the whole answer.

```bash
cd "~/0xDEAD/Saam&Amirali/irallymeter"
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk   (53.2 MB)
```

**A release build removes the debug surfaces by construction, not by hiding
them.** `simulationEnabledProvider` is gated on `kDebugMode`, which is a
compile-time constant, so the release compiler drops the whole subtree *and*
the simulated GPS/motion sources with it. Verified on device:

| In a DEBUG build | In the RELEASE build |
|---|---|
| Settings → **DEBUG** section | **Not present** |
| **Simulated drive (tunnel)** switch | **Not present** |
| GPS fed from **Niayesh Tunnel, Tehran** (35.7745, 51.386) when that switch is on | **Impossible** — the simulated source is not in the binary |

So "the GPS is set to Iran" is not a setting anyone has to undo. It only ever
happens in a debug build with that switch deliberately turned on, and there is
no switch to turn on in the build you hand over.

---

## Then install it CLEAN

```bash
adb uninstall com.irallyclub.irallymeter          # or delete the app on the phone
adb install build/app/outputs/flutter-apk/app-release.apk
```

**Uninstall first, do not install over the top.** All the accumulated
state — route sessions, Trip A/B, ODO, calibration, the section log, and the
"already onboarded" flag — lives in the app's own Hive box. Uninstalling clears
it; installing over the top keeps it, and the tester would inherit whatever was
on the device before.

A clean install was verified to show exactly this:

* permission rationale screen on first launch
* Trip A `0.00`, Trip B `0.00`, ODO `0 m`, AVG `0`
* calibration `1.0000` (`+0.00%`)
* **ROUTE SESSIONS → "No saved sessions"**
* no DEBUG section anywhere

---

## What the tester will see on first launch

1. A one-screen explanation of why the app needs location and notifications,
   and where the data goes.
2. **Allow location** — "While using the app" is enough; the foreground service
   is what keeps it running with the screen off.
3. **Allow notifications** — this is what keeps the trip recording when the
   screen is off. Denying it can freeze the counter mid-stage.

Saying no to either still opens the app. It just reads `GPS LOST` and measures
nothing, which is honest rather than broken. There is currently **no in-app way
to change your mind** — that needs Android Settings → Apps → iRallyMeter →
Permissions. (Open question B7 for Amirali.)

---

## Signing — read this before it goes anywhere real

`android/app/build.gradle:45` is `signingConfig = signingConfigs.debug`, so the
release APK is signed with the **debug keystore**. Fine for sideloading to a
phone you control. **Not fine for Cafe Bazaar, Myket or Play**, and worse, an
app first installed with a debug key cannot later be updated with a real one
without uninstalling. Generate a proper upload key before any distribution.

---

## What to report back

`docs/ROAD-TEST.md` is the full protocol; `docs/PHASE3-SIGNOFF.md` is what makes
Phase 3 complete. The short version, in priority order:

1. **Toggle location off for a minute mid-drive, then back on, without
   restarting the app.** Does the trip counter start advancing again? **This is
   the one unproven fix, and a failure REOPENS Phase 3.**
2. A real tunnel. Distance within ~3 %, no jump or reversal on exit, and
   **STREAM STALLS still 0** (Settings → Section log).
3. A measured 50 km against markers → the error %.
4. City traffic and a twisty road → just report the numbers, pass or fail. They
   are the inputs to the §6.1 and calibration decisions, and tuning either
   before a real number exists would be guessing.

Numbers, not impressions. Settings → Section log has a GNSS HEALTH panel with
sustained Hz, longest gap and stream stalls — screenshot it.
