# PLAN.md — Phase 1

**STATUS: awaiting sign-off. Nothing in Phase 2 starts until §0 below is answered.**

Inputs: `SPEC.md` (acceptance), `ARCHITECTURE.md` (what is actually here),
`INTERFACES.md` (the proposed contract). Baseline: `SA-V4` cut from `SA-V3` `8af9bcb`,
**433 pass / 1 skip / 0 fail**, `origin/main` untouched at `c151ca2`.

---

## §0 DECISIONS TAKEN 2026-08-30

**Q1 — ANSWERED: the backend is a SEPARATE REPO.** `irallymeter-api`. Amirali's Flutter
repo never gains a server, a Node toolchain or a set of secrets, and he can merge the
client work without inheriting any of it.

**Q3 — ANSWERED: analytics is CUT, and the rally app is not to be touched.**
Saam: *"dont touch the app, it works perfectly. So we dont want to change anything at
all so be sure of it. Just the login feature we want added."*

⇒ **The operating rule for every remaining phase.** Read literally it is impossible —
adding a login screen is by definition a change to the app — so it is read as the thing
he means: **the existing rally application does not change. Only new surface is added.**

**What that rules out, concretely.** Nothing under `features/{gps,distance,trip,compass,
dashboard,map,settings,replay,route_log,stage_timer,average_speed,onboarding}` is
modified. Not `app.dart`. Not `app_router.dart`. Not `app_constants.dart`. Not one line
of the measurement engine, and not the `replay/` regression net.

**What must still change, stated up front so none of it is a surprise:**

| File | Change | Why unavoidable |
|---|---|---|
| `lib/main.dart:97` | **one line** — `IRallyMeterApp` → the auth gate wrapper | there is no other way to put a screen in front of the app |
| `pubspec.yaml` | new dependencies | no HTTP client and no secure storage exist today |
| `android/…/AndroidManifest.xml` | deep-link intent-filter | the payment gateway has nowhere to return to |
| `ios/Runner/Info.plist` | `CFBundleURLTypes` | same, iOS side |
| `android/app/build.gradle` | the §1 build fix | separate bug fix; he cannot build without it |
| new files under `lib/features/auth/` | the feature itself | — |

Everything else in the client is **new files only**. The design that makes this possible
is in `ARCHITECTURE.md` §8.5b, and it is genuinely better than what I had planned before
his answer: gating above `IRallyMeterApp` also stops the GPS engine starting behind the
login screen, which the earlier two-site plan had to handle by hand.

⚠ **The one honest cost.** `integration_test/app_flows_test.dart` calls `app.main()` six
times, so all five integration tests would meet the login screen. They will seed an
authorised state through the same storage seam the onboarding flag already uses. **No
assertion is weakened** — that is the repo's existing pattern, not a new exemption.

---

## §0b Still open

**Q2 — is `SA-V4` on `SA-V3` the right base?** Unchanged: `SA-V1→V3` are 115 unmerged
commits with no PR. Recommendation stands — keep the base, and push Amirali to merge
`SA-V3` first.

**Q4 — the onboarding copy.** `permission_rationale_screen.dart:179-184` tells the user
*"There is no account, no analytics and no server."* Cutting analytics fixes one third of
that; **"no account" and "no server" are still made false by this feature.** This is the
one place where "change nothing" and "be truthful to users" collide. It is a text-only
edit in one paragraph, no functional risk, and the two tests that touch it assert only
the heading. **Recommended, but it is his product's voice and his call — if the answer is
still no, the copy ships as-is and this note is the record that it was raised.**

---

## §0c Superseded — the original four questions

**Q1 — Where does the backend live?** This is a Flutter repo owned by Amirali. `main` is
a single commit by him and has never advanced; `SA-V1→V3` are **115 unmerged commits with
no PR**. Adding a Node/Prisma backend to it either makes this a monorepo or belongs in a
separate repo. Getting it wrong is a 100-file move later.
*Recommendation:* **separate repo** (`irallymeter-api`). The backend deploys on its own
cadence, has its own language, toolchain and secrets, and Amirali can merge the Flutter
work without inheriting a server.

**Q2 — Is `SA-V4` on top of `SA-V3` the right base?** It inherits everything good, and it
also means Amirali must merge SA-V3 before he can sensibly review this. The alternative is
branching from `main`, which throws away 115 commits of fixes.
*Recommendation:* keep `SA-V4` on `SA-V3`, and **push Amirali to merge SA-V3 first.**

**Q3 — The eight analytics events** (`ARCHITECTURE.md` §8.9). Two existing documents and
the onboarding screen all promise "no analytics". Name a first-party sink, or drop them.
*Recommendation:* **drop them for v1.** They are the only part of the brief with no
consumer, and they contradict a promise already shipped to users.

**Q4 — The onboarding copy** (`ARCHITECTURE.md` §8.1). The app currently tells users
"There is no account, no analytics and no server." That becomes false. Who rewrites it,
and does Amirali need to approve the new wording? It is his product's voice.

---

## §1 Step zero, independent of everything above

**Fix the Gradle configuration-time throw.** `ARCHITECTURE.md` §8.2, confirmed with a
control: a clone without `key.properties` cannot configure **even a debug build**, so
**Amirali cannot build his own app today.** That blocks his road test, his PR and this
entire brief.

Two-line fix: move the check out of the `buildTypes { release { … } }` configuration
closure so it fires only when a release variant is actually assembled. Its own commit, on
its own, cherry-pickable to a branch he can use immediately. Verified the same way it was
found: hide `key.properties`, `assembleDebug --dry-run` must exit 0; restore it, a release
task must still fail loudly.

---

## §2 Order of work, and why this order

1. **Backend skeleton + schema + migrations.** Everything else asserts against it.
   Prisma, Neon, the six tables from `SPEC.md` §5.1, the two unique constraints that make
   duplicate callbacks harmless. No routes yet.
2. **Auth core.** Phone normalisation first — it is the one thing that corrupts data
   permanently if it lands late. Then Infobip send/verify behind an interface, then
   sessions, rotation and reuse detection.
3. **Device authority.** One active device, `DEVICE_CONFLICT` on a second, Force Login as
   the only transfer path. Built after sessions because revocation is a session operation.
4. **Subscription.** `expires_at` arithmetic, including the extend-from-existing-expiry
   rule that is easy to write backwards. Then the non-authoritative cleanup job.
5. **Payments.** Last on the backend, because it depends on subscriptions existing and is
   the one place a bug costs real money.
6. **Native deep link.** Android intent-filter + `onNewIntent`; iOS `CFBundleURLTypes` +
   `AppDelegate`. Small, but on the critical path and currently absent on both platforms.
7. **Flutter client.** Secure storage, install UUID, API client, entitlement
   verification, then the screens — **all new files**, plus the one-line swap at
   `main.dart:97` (`ARCHITECTURE.md` §8.5b). Then seed the five integration tests.
8. **The onboarding copy rewrite** — *only if Q4 comes back yes.*

Tests are written **first** for each of the twenty cases in `SPEC.md` §7, per that
section. Infobip and ZarinPal are mocked at the HTTP boundary throughout.

---

## §3 What I will not do without being told to

- Touch anything in `ARCHITECTURE.md` §7 — the measurement engine and its regression net.
- Put a network call anywhere on the measurement path.
- Replace `AGENTS.md`. Its numbers are stale; its rules are not (`ARCHITECTURE.md` §8.7).
  It gets **amended**.
- Claim Infobip or ZarinPal works. **Neither can be verified here** — all ten env vars are
  unset and there are no credentials on this machine. They ship as **UNVERIFIED**, built
  against mocks, with a written runbook for the first live test.

---

## §4 The three risks I would bet on going wrong

1. **The Rial/Toman ×10.** Mitigated by storing the unit on every payment row and by
   asserting the exact integer sent to the gateway in a test, not the Toman price.
2. **The one-device revocation race** — a Force Login landing while the old device has a
   refresh in flight. Both paths mutate the same session family. This needs a transaction
   and a test that interleaves them deliberately; `SPEC.md` §8.4 asks Codex to attack
   exactly this, and it will find it if it is wrong.
3. **The offline grace window** (`ARCHITECTURE.md` §8.8). The failure mode is a co-driver's
   numbers blanking mid-stage. The proposed rule — evaluate at session start only, never
   during a run — is in `INTERFACES.md` §5 and needs sign-off, not inference.
