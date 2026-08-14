# Signing key — READ THIS BEFORE THE FIRST RELEASE

## Why this document exists

Every Android app is cryptographically signed. Until 2026-08-14 this app was
signed with the **debug key**: the throwaway one the Android tooling generates
automatically, identical on every developer's machine and effectively public.

That is fine for sideloading and fatal for anything else:

* **Cafe Bazaar, Myket and Google Play all reject debug-signed apps.**
* **An app can only ever be updated by the key that first signed it.** Install
  with one key, try to update with another, and Android refuses. The only way
  through is uninstall and reinstall, **which deletes every saved trip**.
* **If the key is lost, the app can never be updated again.** Not recoverable by
  anyone. A new key means a new listing and every user reinstalling from scratch.

Nobody had generated one, so one was generated.

## The key

| | |
|---|---|
| **File** | `~/Personal/keys/irallymeter-release.jks` |
| **Alias** | `irallymeter` |
| **Password** | in `android/key.properties`, which is gitignored. **Not recorded here on purpose — this file is committed and pushed.** |
| **Validity** | 10,000 days, to 2053 |
| **SHA-256** | `46:52:F1:0A:16:C4:2F:08:46:A0:B9:AE:D8:28:26:DD:CF:38:34:A8:64:CD:1C:4E:3B:A5:0A:CB:31:5E:9E:D7` |

**⚠ THE KEYSTORE FILE AND ITS PASSWORD ARE NOT IN THIS REPOSITORY AND MUST NOT
BE.** `android/.gitignore` already excludes `key.properties`, `*.jks` and
`*.keystore`. The build reads `android/key.properties`, which points at the
file above.

## What has to happen now, and it is not optional

**Back the keystore up somewhere it cannot be lost**, today:

1. The `.jks` file into a password manager as an attachment, or an encrypted
   backup that is not just this laptop.
2. The password stored with it.
3. Ideally a second copy held by Amirali, since it is his project.

A laptop failure with no backup ends the app's ability to ever ship an update.

## Verifying a build is really signed

```bash
flutter build apk --release
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
"$HOME/Library/Android/sdk/build-tools/36.0.0/apksigner" verify --print-certs \
  build/app/outputs/flutter-apk/app-release.apk
```

The DN must read `CN=iRallyMeter` and the SHA-256 must match the table above.
If it says `CN=Android Debug`, `key.properties` was not found and the build
silently fell back to debug signing.

## The fallback is deliberate

`android/app/build.gradle` uses the release config **only when
`key.properties` exists**, and debug signing otherwise. So a fresh clone builds
without the key rather than failing, and CI or another developer is never
blocked. The cost is that a missing key file downgrades silently, which is
exactly why the verification step above exists.

## ⚠ Testers who already have the old build

Anyone running a previously sideloaded APK — including Amirali's father — is
running a **debug-signed** install. The new signed build **will not install over
it**. They must **uninstall first**, and doing so **erases their saved trips**.

This is why the key had to land before testing accumulated data worth keeping.
It is a one-time cost, and it only gets more expensive the longer it waits.
