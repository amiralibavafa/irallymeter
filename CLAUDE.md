# CLAUDE.md — iRallyMeter account & payment layer

Scope: the work specified in `SPEC.md`. Everything else in this repo is governed by
`AGENTS.md` and `docs/SPEC-v2.md`, which still win on measurement behaviour.

## 1. THINK BEFORE CODING
State assumptions out loud before writing code. If a requirement has more than one
reading, present both rather than picking one silently. If it is unclear, **stop and
ask** — a wrong guess in auth or payments is not cheap to unwind.

## 2. SIMPLICITY FIRST
The minimum code that satisfies `SPEC.md`. No features beyond it. No abstraction for a
single call site. No "flexibility" nobody asked for. No error handling for states that
cannot occur — and no swallowing of ones that can.

## 3. SURGICAL CHANGES
Touch only what the task requires. **Do not refactor adjacent rally or GPS code**, and
do not reformat, re-comment or "tidy" files you are only reading. Match the surrounding
style. The list in `ARCHITECTURE.md` §7 is off limits: GPS ingest, speed filtering,
distance integration, tunnel estimation, trip counters, compass, `app_constants.dart`,
and the `replay/` regression net.

## 4. GOAL-DRIVEN EXECUTION
Write the success criterion before the code, then verify it before saying you are done.
`flutter analyze` stays at its 2 pre-existing issues. `flutter test` stays green from
its **433 pass / 1 skip / 0 fail** baseline. Backend tests run green before any merge.
**Never weaken an assertion to make a suite pass** — say whether the code or the test is
wrong.

## 5. WHAT MUST SURVIVE A COMPACTION
If context is compacted, these are reconstructed first, from disk, never from memory:

- **Schema + migration state** — which migrations exist, which have been applied, and
  against which database.
- **`INTERFACES.md`** — the contract. It is the single source of truth for every route,
  field, enum and lifetime, and **any change to it stops work for sign-off.**
- **The env var list** (`SPEC.md` §4.5) and which values are still missing.
- **Failing tests**, by name, and what each one was proving.
- **Native platform-channel and deep-link decisions** — the `irallymeter://` scheme,
  the Android `onNewIntent` path, the iOS `AppDelegate` hook.

## 6. Non-negotiables carried from SPEC.md
- The client **never** holds a database credential. App → HTTPS → backend → Neon.
- The backend is the **only** authority on OTP, payment, subscription and device state.
  A client claim that a payment succeeded is not evidence of anything.
- `expires_at` on the **server** clock decides validity. Never a countdown, never the
  device clock.
- **Never invent a credential.** Never fabricate an SMS or payment response. Never
  report an integration as working when it has not been run against the real service.
- **Never log** a PIN, a `pinId` next to a phone number, a token, or a payment secret.
- Phone numbers are normalised to E.164 **before** any lookup, insert or send.
- Device identity is a random installation UUID. **Never IMEI. Never IP.**

## 7. Git
Never commit or push to `main`. Never force-push. Work on `SA-V<n>`; this work is on
`SA-V4`. **Stage explicit paths — `git add -A` and `git add -u` are both banned here**,
they have already swept an unrelated regression into a commit. Open a PR; do not merge.
