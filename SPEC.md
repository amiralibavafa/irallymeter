# SPEC.md — Accounts, SMS OTP, One-Device Security, Subscription and Payment

**This is the source of truth for acceptance of the ACCOUNT/PAYMENT work only.**

> ⚠ **Two SPEC files exist in this repo and they cover different things.**
> `docs/SPEC-v2.md` is the *rally measurement* specification: GPS, speed, distance,
> tunnels, compass. It is unchanged and still governs everything under
> `lib/features/{gps,distance,trip,dashboard}`.
> **This file governs only the new account, authentication, subscription and payment
> layer.** Where they appear to conflict, `docs/SPEC-v2.md` wins on measurement and
> this file wins on accounts. Neither may weaken the other.

Recorded verbatim from the engagement brief on 2026-08-30. Section numbering added
for citation; wording is the author's.

---

## §1 Task

iRallyMeter — implement the complete phone-auth, SMS OTP, one-device security,
subscription, and ZarinPal payment backend + client integration for an EXISTING
hybrid mobile app (Flutter/Dart + native Android/Kotlin + native iOS/Swift).
Preserve the existing offline rally application entirely.

---

## §2 Phase 0 — Recon (no code, read-only)

1. Run `repomix` at repo root to pack the project, then produce an architecture scan:
   - Module map (one sentence per folder/file)
   - Dependency graph
   - Does a backend/API already exist? Which runtime/framework?
   - Existing Flutter auth/payment/HTTP architecture
   - Existing native Kotlin/Swift integrations and platform channels
   - Existing env/config files, existing Neon configuration, existing dependencies
   - What is well-designed and must NOT be touched
2. Write findings to `ARCHITECTURE.md`.
3. Save this entire spec to `SPEC.md` — it is the source of truth for acceptance.

**CRITICAL:** Do NOT assume this is a Flutter-only project. Do NOT assume the repo is
empty. Do NOT create duplicate routes/services where equivalents already exist.
Why: rewriting working native integrations is the highest-cost failure mode here.

---

## §3 Phase 1 — Plan

Enter plan mode. `/effort high`. Use context7 for Infobip 2FA, ZarinPal, Neon
serverless Postgres, Prisma, JWT, and `flutter_secure_storage` docs — do not code
against remembered APIs.

Use the `api-designer` subagent and the `backend-architect` subagent to produce the
plan. Use Superpowers' brainstorming + writing-plans skills to refine the spec
before any implementation.

Deliverables of this phase:
- Written plan (Ctrl+G opens it in an external editor for review)
- `INTERFACES.md` at repo root: the exact contracts between backend, Flutter, and
  native layers (route shapes, request/response JSON, error/state enums such as
  `DEVICE_CONFLICT` / `SUBSCRIPTION_EXPIRED` / `OTP_INVALID`, token lifetimes).
  **RULE: any later change to anything in `INTERFACES.md` STOPS and flags for
  sign-off before proceeding.**
- `CLAUDE.md` rules block (keep under 65 lines):
  1. THINK BEFORE CODING — state assumptions; if multiple readings exist, present
     them; if unclear, stop and ask.
  2. SIMPLICITY FIRST — minimum code that satisfies `SPEC.md`. No features beyond it.
  3. SURGICAL CHANGES — touch only what the task requires; do not refactor adjacent
     rally/GPS code; match existing style.
  4. GOAL-DRIVEN — define success criteria before coding; verify before stopping.
  5. Compaction rules — always preserve: schema state, migration status,
     `INTERFACES.md`, env var list, failing tests, native platform-channel decisions.

---

## §4 Hard invariants (non-negotiable; violating any one is a build failure)

**§4.1 CRITICAL** — Flutter/native MUST NEVER connect to Neon PostgreSQL. Only the
backend holds DB credentials. Architecture: **App → HTTPS → Backend API → Neon Postgres.**

**§4.2 CRITICAL** — The backend is the sole authority for: OTP verification, payment
verification, subscription activation/extension, device authorization.
**NEVER trust a client claim that a payment succeeded.**

**§4.3 CRITICAL** — `expires_at` (server clock) is authoritative for subscriptions.
NEVER decrement a counter on a schedule. NEVER trust the device clock.
Validity = `current_server_time < expires_at`. The cleanup job keeps status rows
consistent but is **NOT** the authority.

**§4.4 CRITICAL** — GPS, speedometer, trip meters, odometer, compass, rally
calculations, and offline maps MUST keep working with zero connectivity and MUST NOT
gain any API dependency. Do not move any of it server-side.

**§4.5** — NEVER hardcode or invent credentials. Infobip and ZarinPal values live in
env vars only: `INFOBIP_API_KEY`, `INFOBIP_BASE_URL`, `INFOBIP_2FA_APPLICATION_ID`,
`INFOBIP_2FA_MESSAGE_ID`, `ZARINPAL_MERCHANT_ID`, `ZARINPAL_CALLBACK_URL`,
`ZARINPAL_SANDBOX`, `DATABASE_URL`, `JWT_ACCESS_SECRET`, `JWT_REFRESH_SECRET`.
Ship `.env.example` with names only. Never commit `.env`. Never fabricate a successful
SMS or payment response, and never report an integration as "working" untested.

**§4.6** — NEVER log OTP values, PIN IDs paired with phone numbers, tokens, or payment
secrets.

**§4.7** — ALWAYS use Infobip's own 2FA PIN generation and verification (application →
message template → send PIN → receive `pinId` → verify PIN). Do NOT write a custom
OTP generator.

**§4.8** — ALWAYS normalize Iranian numbers to E.164 (`09xxxxxxxxx` → `+989xxxxxxxxx`)
BEFORE any lookup, insert, or send. Phone is UNIQUE. Why: format drift creates
duplicate accounts.

**§4.9** — Device identity = a persistent random installation UUID in secure storage.
**NEVER IMEI. NEVER IP-as-identity** (IP may be logged for audit only).

---

## §5 Phase 2 — Backend

Use the `backend-developer` subagent and the `postgres-pro` subagent. Use context7
throughout.

### §5.1 Database (Neon project `lingering-shape-75754502`, org Amirali)

- Connect via `DATABASE_URL` env var, pooled connection, TLS required.
- Use a real migration system — `/prisma-database-setup` and `/prisma-cli` for schema
  + migration workflow, `/prisma-client-api` for the query layer, `/prisma-postgres`
  for Neon/Postgres-specific connection and pooling patterns. Apply the Postgres
  indexing, constraint, and transaction guidance in
  `/supabase-postgres-best-practices` (**vendor-neutral Postgres parts only — this
  project is Neon, not Supabase**).
- Tables:
  - `users` (id, phone UNIQUE, created_at, updated_at)
  - `devices` (id, user_id, device_id, platform, device_name, app_version, created_at,
    last_seen, revoked_at)
  - `subscriptions` (id, user_id, plan, price, started_at, expires_at, status,
    payment_id, created_at, updated_at)
  - `payments` (id, user_id, subscription_id, plan, amount, currency_unit, gateway,
    authority, reference_id, status, created_at, updated_at)
  - `refresh_tokens` (**hashed only**)
  - `plans` (configurable — seed exactly ONE active plan: monthly, 400,000 Toman, 30 days)
- **Collect NOTHING beyond phone**: no name, email, address, gender, DOB, referral source.
- **Idempotency:** UNIQUE constraint on `(gateway, authority)` and on `reference_id` so
  a replayed callback cannot activate a second subscription.

### §5.2 Routes (adapt to existing structure if equivalents exist)

```
POST /auth/send-otp
POST /auth/verify-otp
POST /auth/login
POST /auth/force-login
POST /auth/logout
POST /auth/refresh
GET  /subscription/status
POST /payment/create
GET|POST /payment/callback
```

### §5.3 Auth logic

- Passwordless. Phone → Infobip PIN → verify → branch:
  no account → signup+payment flow; account exists → device check → subscription check.
- **ONE active device per account.** A second device on NORMAL login is REJECTED with an
  explicit `DEVICE_CONFLICT` state — it must **NOT** silently replace the existing device.
- **Force Login:** requires a fresh successful OTP, then revokes prior device + sessions,
  registers the new device, issues a new session. This is the deliberate transfer path.
- **Logout:** revoke refresh token + device session server-side, then clear client state.
- Short-lived access token + long-lived refresh token, **refresh rotation**, refresh
  tokens stored **HASHED**. Silent refresh so the user never re-OTPs on app open.

### §5.4 Subscription logic

- **Renewal while active EXTENDS from the existing `expires_at`, not from now.**
  Test case: expiry Sep 10, purchase Sep 5 → new expiry **Oct 10** (never Oct 5).
- Renewal while expired starts from now.
- Every authenticated request validates: account exists → session valid → device
  authorized → subscription not expired. Expired returns an explicit
  `SUBSCRIPTION_EXPIRED` state, **not a generic 401**.
- Add a scheduled job to mark lapsed rows expired, clearly documented as
  **non-authoritative**.

### §5.5 Rate limiting / abuse (our own layer, on top of Infobip's)

Per-phone and per-IP limits on `send-otp` and `verify-otp`, plus login attempt limiting.
Respect the configured Infobip envelope: **PIN TTL 15 min, 10 attempts, 1 verify /
3 seconds, 100 sends/day app-wide, 10 sends/day per phone.**

### §5.6 Payments (ZarinPal)

Flow: client requests → backend creates the payment row (status `pending`) and the
gateway request → gateway → callback → **backend VERIFIES with ZarinPal** → backend
activates/extends the subscription → client is told the confirmed state.

**Verify the current ZarinPal amount unit (Rial vs Toman) from live docs via context7
before writing any amount conversion — do not assume.** Store the unit explicitly in
the `payments` row.

Apply `/webhook-handler-patterns` for retry, replay, and idempotency handling of the
callback, and mirror the idempotency-key + event-dedupe structure documented in
`/stripe-webhooks` as the reference pattern (**ZarinPal is the gateway here, Stripe is
only the pattern source**).

---

## §6 Phase 3 — Client

Use the `mobile-developer` subagent; use the `swift-expert` subagent for any iOS
platform-channel work. Use context7 for the ZarinPal Flutter package — **INSPECT the
package's current API surface before wiring it; do not code from memory.**

- **Secure token storage:** Keychain on iOS, EncryptedSharedPreferences/Keystore on
  Android (via `flutter_secure_storage` or the existing native equivalent already in
  the repo). **NEVER SharedPreferences/UserDefaults plaintext** for tokens or entitlement.
- Persistent installation UUID generated once, stored in the same secure store.
- **Offline entitlement:** cache a SIGNED, server-issued entitlement blob (server
  signature + `expires_at` + `issued_at` + `device_id`) so the rally app runs offline.
  Reconcile on every successful connectivity window. Enforce a **bounded offline grace
  period** — after N days without reconciliation the entitlement stops being accepted.
  **Tampering with local storage must not yield indefinite access.**
  Why: this is the one place where offline-first and revocation are in tension —
  design it explicitly, don't let it emerge.
- Screens: phone entry → OTP → (membership + payment if new/expired) → app.
  Login screen carries: *Not a member? Sign up* · *Force Login (!)* with an info tooltip
  explaining lost/damaged/inaccessible previous phone or forgotten logout.
  `DEVICE_CONFLICT` must render a clear "already active on another device" state.

### §6.1 UI quality gates for the auth/membership screens

- `/design-interview` **BEFORE** building the screens (lock states, copy, error surfaces).
- `/signup-flow-cro` on the phone→OTP→membership funnel and `/paywall-upgrade-cro` on the
  membership/renewal screen — reduce friction **without adding fields**.
- `/design-review` after building (8-dimension score + AI-slop checklist + top 3 fixes).
- `/site-qa` on the ZarinPal web return/callback page (the one genuine web surface) —
  responsiveness, RTL/Persian rendering, and failure-state handling.
- `/analytics-tracking` to instrument ONLY this funnel: `otp_requested`, `otp_verified`,
  `membership_viewed`, `payment_started`, `payment_verified`, `login_device_conflict`,
  `force_login_used`, `logout`. **Events only — build NO analytics dashboard (§23 forbids it).**

---

## §7 Phase 4 — Tests

Use the `qa-expert` subagent. Superpowers' test-driven-development skill: **write the
failing test first for every item below.**

Must cover:

1. new-user signup
2. OTP verify success / failure / expiry
3. existing-user login
4. duplicate-phone normalization (`09…` and `+989…` resolve to ONE account)
5. device registration
6. **SECOND-DEVICE REJECTION on normal login**
7. force login revokes prior device
8. logout revokes session
9. refresh rotation
10. refresh reuse detection
11. expired subscription blocks access
12. active subscription allows access
13. **RENEWAL EXTENDS from existing expiry**
14. payment creation
15. verified payment activates subscription
16. failed payment activates nothing
17. **DUPLICATE CALLBACK activates exactly one subscription**
18. unauthorized requests rejected
19. expired subscription cannot reach an authenticated session without a verified payment
20. tampered local entitlement is rejected on reconciliation

**Mock Infobip and ZarinPal at the HTTP boundary. Never hit live gateways in tests.**

---

## §8 Phase 5 — Review

Run `/code-review` on the full diff (4 parallel auditors, ≥80 confidence filter).
Then the cross-model adversarial loop — this build hits every high-risk trigger
(auth, payments, migrations, session lifecycle):

1. Write `AGENTS.md` at repo root before handing anything to Codex — Codex never reads
   `CLAUDE.md`. ~100 lines: stack, conventions, git rules, and an explicit ownership
   boundary: *"Claude Code owns `SPEC.md`, `INTERFACES.md`, `ARCHITECTURE.md` and memory;
   Codex may read them but never writes them."*
   Set `~/.codex/config.toml` → `model = "gpt-5.5"`, `model_reasoning_effort = "high"`
   (`codex exec` defaults to reasoning effort NONE — check the header line it prints).
2. `/codex:review --background`
3. Fix everything Codex flags.
4. `/codex:adversarial-review` — challenge the payment callback idempotency, the
   refresh-token rotation and reuse-detection design, the one-device revocation race
   (force login racing an in-flight refresh from the old device), and the offline
   entitlement grace window.
5. Fix remaining issues.
6. **Ship only when adversarial review returns nothing critical.**

Also: use the `security-auditor` subagent for a pass over token handling, secret
placement, parameterized queries, and log redaction.

---

## §9 Parallelism

Use git worktrees (`claude -w <branch>`) with **STRICT module ownership** so parallel
agents cannot create logic conflicts:

- agent **A** owns `backend/` (DB, auth, subscription, payments)
- agent **B** owns the Flutter client + native platform channels
- agent **C** owns `tests/` and fixtures

Every agent reads `INTERFACES.md` **FIRST**. Any interface change stops for sign-off.
**Tests are the merge judge — only branches with green tests merge.**
**CAP: 3 max concurrent subagents** (subagent queue pattern, SOP §11.6) — this is the
subagent limit, NOT the 25-concurrency figure used for native batch scraping.

---

## §10 Context management

Run `/context` before starting to check the baseline. Run `/compact` every ~30 minutes
focused on: current phase, schema + migration state, `INTERFACES.md` contracts, env
var list, failing tests, unresolved native platform-channel decisions.
Use `/btw` for side questions so they cost nothing against this thread.
After each phase, append what broke and the rule learned to `tasks/lessons.md`;
read `tasks/lessons.md` before starting each new phase.

---

## §11 Output format

Final engineering report (concise, factual, **no claims of untested success**):
existing architecture discovered · backend architecture used · Neon connection
status · schema created · migration status · Infobip integration status · ZarinPal
integration status · auth flow · device security flow · subscription system ·
offline entitlement behavior · env vars required · files created/modified · tests
written and passing · remaining manual credentials/config needed.

**State explicitly which integrations are UNVERIFIED pending real credentials.**
