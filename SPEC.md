# SPEC.md — Accounts, SMS OTP, One-Device Security, Subscription and Payment

**This is the source of truth for acceptance of the ACCOUNT/PAYMENT work only.**
Recorded from the engagement brief of **2026-09-08**. Section numbering added for
citation; the wording is the author's.

> ⚠ **Two SPEC files govern different things.** `docs/SPEC-v2.md` is the *rally
> measurement* specification: GPS, speed, distance, tunnels, compass. It is unchanged and
> still governs everything under `lib/features/{gps,distance,trip,dashboard}`. **This file
> governs only the new account, authentication, subscription and payment layer.** Where
> they appear to conflict, `docs/SPEC-v2.md` wins on measurement and this file wins on
> accounts. Neither may weaken the other.

> The 2026-08-30 brief is archived verbatim at **`SPEC-2026-08-30.md`** and is no longer
> acceptance criteria. It is kept because decisions were taken against it.

---

## §0 What changed from the 2026-08-30 brief

| # | Change | Consequence |
|---|---|---|
| 1 | **The named SMS provider is OUT.** Replaced by a research phase with an approval gate. | Nothing may be built against a provider until Saam approves the choice. See §3. |
| 2 | **A `<preservation_contract>` was added** and is called *"the highest-priority constraint in the entire task."* | §2. Mechanically enforced by `BASELINE-SA-V4.md`. |
| 3 | **Analytics is back** — 9 named events. | Reverses the 8-30 "analytics is CUT". Recorded, not erased, in `INTERFACES.md` §3. |
| 4 | **Routes renamed** `send-otp`→`send-code`, `verify-otp`→`verify-code`. | `INTERFACES.md` reconciled 2026-09-08. |
| 5 | **New state enums the UI branches on.** | §6.2. `NO_SUBSCRIPTION` became `NO_ACCOUNT`. |
| 6 | **Phase 0 now also requires a design-token inventory.** | Delivered as `ARCHITECTURE.md` §11. |
| 7 | **The SMS provider must sit behind an abstraction** swapped by env var only. | §5.7. No provider name in business logic. |

---

## §1 Task

iRallyMeter — implement the complete phone-auth, SMS OTP, one-device security,
subscription and payment layer, as a **gate in front of the existing app**, without
modifying the rally computer.

App → HTTPS → Backend API → Neon Postgres. The Flutter app is a client of an HTTP API and
nothing else.

---

## §2 The preservation contract — the highest-priority constraint in the entire task

> *"NEVER modify: GPS logic, speedometer, trip meters, odometer, compass, offline
> navigation, existing Kotlin integrations, existing Swift integrations, existing Flutter
> rally logic, existing tests, or any currently-working file."*
>
> *"If a previously passing test breaks, STOP and revert — do not 'fix' the rally code."*

Saam, twice, in his own words:

> *"the app wont be and cant be touched as the team approved it and like where its at so we
> wont touch that at all, we are only creating that gate i mentioned"*

**The mechanical test of this contract is `BASELINE-SA-V4.md`: 433 pass / 1 skip / 0 fail,
`flutter analyze` at exactly 2 pre-existing issues.** Re-run after every phase. If either
number moves, stop and revert. The 1 skip stays skipped at full strength.

**The gate goes in at `lib/main.dart:97`**, above `IRallyMeterApp`, which is one line and
leaves `app.dart` and `app_router.dart` untouched. This also means the GPS engine cannot
start behind the login screen, because the chain at `app.dart:29` never runs until the gate
passes. Both construction sites are enumerated: `main.dart:97` and
`test/onboarding_test.dart:225` (the unit test builds the widget directly and so bypasses
the gate by design).

---

## §3 Phase 1 — SMS provider research, WITH AN APPROVAL GATE

Use the `researcher` subagent. **3+ independent sources per claim.**

Evaluate SMS providers on:
1. Real deliverability to Iranian **+98** numbers across **MCI (Hamrah-e Aval), Irancell,
   Rightel**.
2. **Sanctions and onboarding reality** — can this account actually be opened and paid for?
3. **Does the provider generate AND verify the PIN server-side, or does it only send a
   message we compose?** This decides whether an `otp_codes` table is needed at all.
4. **Template / pattern pre-approval** — is it required, and what is the lead time?

Output: **`SMS_PROVIDER_DECISION.md`**.

> *"Do not present a provider as confirmed-working on the basis of marketing copy. Mark
> unverified claims as unverified. **I will approve the choice before you build against
> it.**"*

**This is a hard stop.** Phases 2-6 do not start until that approval lands.

---

## §4 Hard invariants — non-negotiable; violating any one is a build failure

Recorded verbatim.

- **CRITICAL** — The mobile app MUST NEVER connect to PostgreSQL. App → HTTPS → Backend API
  → Neon Postgres. Only the backend holds `DATABASE_URL`.
- **CRITICAL** — The backend is the sole authority for OTP verification, payment
  verification, subscription activation, and device authorization. **NEVER trust a client
  claim that a payment succeeded.**
- **CRITICAL** — Subscription validity is `NOW() < expires_at` on **SERVER** time. NEVER
  decrement a day counter on a schedule. NEVER trust the device clock.
- **CRITICAL** — The rally computer must run with **zero connectivity** and must gain **NO
  new API dependency**. The speedometer never awaits a network call.
- **NEVER hardcode credentials.** Everything through env vars. Ship `.env.example` with
  names + TODO comments only, never values. Never commit `.env`.
- **NEVER fabricate** a successful SMS send or payment response. Never report an integration
  as working unless it was actually exercised.
- **NEVER log** OTP values, provider message IDs paired with phone numbers, tokens, or
  payment secrets.
- **ALWAYS normalize** Iranian numbers to E.164 (`09xxxxxxxxx` → `+989xxxxxxxxx`) BEFORE any
  lookup, insert, or send. `phone` is UNIQUE.
- **Device identity** = a persistent random installation UUID in secure storage. **NEVER
  IMEI. NEVER IP-as-identity** (IP may be logged for audit only).
- Mock the SMS provider and ZarinPal **at the HTTP boundary. Never hit live gateways.**

---

## §5 Phase 2 — Backend

### §5.1 Database

Neon serverless Postgres, Prisma 7.10.0 (both `prisma` and `@prisma/client` pinned
**exactly**, because Prisma's `latest` dist-tag points at a release candidate).

Models: `User`, `Device`, `Plan`, `Subscription`, `Payment`, `RefreshToken`, plus a
**session table for the OTP handshake** whose exact shape is decided by §3 — if the chosen
provider verifies the PIN itself, it stores only a provider handle; if it does not, it
stores a **hashed** code with a TTL and an attempt counter.

Three partial unique indexes are hand-written SQL, because Prisma cannot express them:

```sql
CREATE UNIQUE INDEX "devices_one_active_per_user"
  ON "devices" ("user_id") WHERE "revoked_at" IS NULL;
CREATE UNIQUE INDEX "subscriptions_one_active_per_user"
  ON "subscriptions" ("user_id") WHERE "status" = 'ACTIVE';
CREATE UNIQUE INDEX "otp_sessions_one_live_per_phone"
  ON "otp_sessions" ("phone") WHERE "consumed_at" IS NULL;
```

The first is the **database-level enforcement of one-device**, proven with a control on
both sides: a second active device is refused; after a Force Login revokes the first, the
second is accepted; the revoked row is retained for audit.

### §5.2 Routes

`POST /auth/send-code` · `POST /auth/verify-code` · Force Login · refresh · logout ·
membership · payment start · `GET|POST /payment/callback` · `POST /analytics/event`.
Full request/response contracts live in **`INTERFACES.md`**, which is the wire contract and
wins on shapes.

### §5.3 Auth logic

Refresh-token **rotation with reuse detection**. An Ed25519-signed offline entitlement blob
lets the app know it is still entitled without a network call, which is what keeps the
rally computer working at zero connectivity.

### §5.4 Subscription logic

`NOW() < expires_at`, server time, every time. Automatic logout on expiry. **A user with a
live subscription who logs in again does not pay again** (Saam, verbatim: *"if they have a
subscriptions and they tryna log in again, they dont need to pay"*).

### §5.5 One device per phone number

Saam, verbatim: *"Every user with the same phone number can only login with one device and
if they try to login with another device while main device is logged in and that shouldnt be
approved/allowed."* Force Login is the escape hatch: it revokes the prior device and every
refresh token issued to it.

### §5.6 Payments — ZarinPal

Classic REST `pg/v4`. **Amounts default to RIAL**; `currency: "IRT"` opts into Toman.
Code `100` = verified now, `101` = already verified. The callback's `Status` is never
trusted; the backend re-verifies with ZarinPal.

**ZarinPal credentials ship as clearly commented TODO placeholders.** Everything else in
the payment path is fully implemented.

### §5.7 SMS provider abstraction

```
sendVerification(phone) → handle
verifyCode(handle, code) → result
```

Swapped **only** by `SMS_PROVIDER` / `SMS_API_KEY` / `SMS_BASE_URL` / `SMS_SENDER_ID`.
**No provider name appears anywhere in business logic.** A fake adapter exists for tests.

---

## §6 Phase 3 — Client

### §6.1 UI quality

The auth, membership and payment screens must be indistinguishable from the existing app.
The token inventory is `ARCHITECTURE.md` §11. Headline: **the theme styles type and colour
only and defines no component themes**, so the CTA is copied verbatim from
`permission_rationale_screen.dart:187-207` and the input style has to be authored once.

### §6.2 States the UI branches on

`OTP_SENT` · `OTP_INVALID` · `OTP_EXPIRED` · `NO_ACCOUNT` · `DEVICE_CONFLICT` ·
`SUBSCRIPTION_EXPIRED` · `PAYMENT_FAILED` · `SESSION_REVOKED`.

The client switches on the code and **never parses a message string**.

---

## §7 Phase 4 — Tests

Mock the SMS provider and ZarinPal **at the HTTP boundary**. Never hit a live gateway.
New tests are additive; **no existing test is edited**.

---

## §8 Phase 5 — Review

Against §2 first, then the hard invariants, then the wire contract.

---

## §9 Open, and owned by Saam

1. **Approve the SMS provider** (§3). Blocks phases 2-6.
2. **Who owns the SMS account** — an Iranian entity or not? This reorders the whole provider
   matrix, because domestic providers generally require Iranian company registration and a
   Shetab card.
3. **The onboarding copy.** `permission_rationale_screen.dart:179-184` promises *"no
   account, no analytics and no server."* This work makes all three false. Flagged, not
   edited.
4. **Neon credentials.** Only Saam has them; `.env` fails loudly by design.
5. **Where `irallymeter-api` lives.** It has no git remote.
6. **The Gradle throw at `android/app/build.gradle:83-87`** blocks Amirali from building the
   app at all. Proven by control. It is my bug from the prior engagement and it is not
   touched without permission.
