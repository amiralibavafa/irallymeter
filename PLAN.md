# PLAN.md — Phase 1

**STATUS: awaiting sign-off. Nothing in Phase 2 starts until §0 below is answered.**

Inputs: `SPEC.md` (acceptance), `ARCHITECTURE.md` (what is actually here),
`INTERFACES.md` (the proposed contract). Baseline: `SA-V4` cut from `SA-V3` `8af9bcb`,
**433 pass / 1 skip / 0 fail**, `origin/main` untouched at `c151ca2`.

---

## §0 Four questions that block Phase 2

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
7. **Flutter client.** Secure storage, install UUID, API client, entitlement verification,
   then the screens. The login gate touches **two** coupled sites (`app_router.dart:48`
   and `app.dart:29`) and fights a documented `ref.read` decision — that is the delicate
   part of the whole client, not the UI.
8. **The onboarding copy rewrite**, in the same release as the gate. Never after.

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
