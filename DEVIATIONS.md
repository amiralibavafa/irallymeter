# DEVIATIONS.md — where the build and the contract disagree

`INTERFACES.md` is the wire contract and **any change to it stops work for sign-off**
(`CLAUDE.md` §5). This file exists so a divergence discovered during a build is *recorded
and escalated* rather than either silently coded around or silently written into the
contract. It follows the shape already set by `irallymeter-api/src/sms/port.ts`, which
flagged the first such deviation in Phase 2 rather than making it quietly.

Nothing in here is a decision. Each entry is a question for Saam.

---

## D-1 — The entitlement blob is a compact JWS, not `{payload, signature}`

**Found:** 2026-09-08, during Phase 3, before a line of the client verifier was written.
**Status: OPEN. Waiting on Saam.** Does not block the rest of Phase 3.

### What `INTERFACES.md` §5 specifies

```json
{ "payload": { "userId": "…", "deviceId": "…", "expiresAt": "…",
               "issuedAt": "…", "graceDays": 14, "version": 1 },
  "signature": "base64(Ed25519(canonical_json(payload)))" }
```

with the client accepting only if **all** hold: signature verifies · `deviceId` matches
this install · `now < expiresAt` · **`now < issuedAt + graceDays`**.

### What the backend actually emits

`irallymeter-api/src/auth/entitlement.ts` signs a **compact JWS** (`EdDSA`), and
`src/accounts/service.ts:39` types the field `entitlement: string | null`. The claims are:

| Claim | Meaning | §5's name for it |
|---|---|---|
| `sub` | user id | `userId` |
| `did` | device id | `deviceId` |
| `iat` | issued at (epoch seconds) | `issuedAt` |
| `exp` | expiry (epoch seconds) | `expiresAt` |
| — | **absent** | **`graceDays`** |
| — | **absent** | `version` |

### The two differences, separated because they are not equally serious

**(a) The shape — JWS instead of `{payload, signature}`. Recommend adopting the JWS.**
This one is a straight improvement and the client is being built against it. `canonical
_json` is a well-known footgun: the verifier must reproduce the server's exact bytes,
including key order, unicode escaping and number formatting, and any disagreement fails
as an invalid signature rather than as a readable error. A compact JWS carries the signed
bytes inside the token, so there is nothing to reproduce. It is also a standard with an
audited implementation on both sides.

**(b) `graceDays` is missing, and that is a real loss, not a formatting detail.**
§5 makes `issuedAt + graceDays` *"what bounds offline use"*. It is a second, tighter
ceiling than `expiresAt`, and it is what limits how long a device that has been
force-logged-out, refunded or cancelled keeps working while it cannot be reached.

> **Consequence, stated as a number because that is what makes it a decision:**
> with `graceDays = 14` an unreachable device stops after **14 days**. Without it the
> only ceiling is the subscription's own expiry, so on the monthly plan the worst case
> is **up to 30 days** — better than double.

The backend's own header comment reasons that `exp` = subscription expiry is a sufficient
bound. That reasoning is coherent, but it is a **relaxation of a stated requirement**, and
`INTERFACES.md` §8 lists `graceDays = 14` **by name** as one of the three things requiring
sign-off before Phase 2 started. So it is Saam's call, not a craft detail to restore
unilaterally, and Phase 2 is not being reopened mid-Phase-3 to add it.

### What the client does in the meantime

The Phase 3 verifier checks: **signature verifies · `did` == this install's UUID ·
`now < exp` · `now >= iat`**, where `now` is the **monotonic high-water mark**, never a
raw `DateTime.now()`.

With `graceDays` absent, `now >= iat` plus that mark carry the entire clock-rollback
defence, so the mark is built to ratchet and persist rather than being advisory. The
verifier is deliberately structured so that **`graceDays` is one added comparison against
the same clock source** on the day it lands — see `entitlement_verifier.dart`.

### The three ways this closes

1. **Accept the JWS, add `graceDays` back** as a claim (a few lines in
   `entitlement.ts` plus one comparison in the client). Amend `INTERFACES.md` §5 to
   describe the JWS. ← recommended
2. **Accept the JWS, accept the loss.** Amend §5 to describe the JWS and to delete
   `graceDays`, recording that the offline ceiling is the subscription term.
3. **Rebuild the backend to §5 as written.** Costs the canonical-JSON problem in (a) for
   no benefit the JWS does not already give.

---

## D-2 — A session can legitimately carry no entitlement blob at all

**Status: NOT a contract conflict. Recorded because it is a live failure mode.**

`irallymeter-api/src/server.ts:42` constructs the signer **only** when
`ENTITLEMENT_PRIVATE_KEY` is set, and `loadConfig` requires that key **only in
production**. So a perfectly valid session can arrive with `entitlement: null` — and it
will, on every environment standing up before the key exists.

`INTERFACES.md` §4 shows `entitlement` inside the subscription object with no null case,
so a client that read it as required would treat a missing blob as "not entitled" and
**lock out a paying user** whenever the backend was started without the key.

The client therefore models it as **nullable**, and a null blob means only *"no offline
proof available"* — never *"not entitled"*. Online, the subscription status is the
authority and the blob is not consulted at all.

---

## D-3 — The backend and `INTERFACES.md` disagree on almost every shape

**Found:** 2026-09-08, during Phase 3, while writing the client's force-login call.
**Status: OPEN. Two decisions for Saam, and they are different kinds of decision.**

### The fact that settles which side wins

`INTERFACES.md` line 3, unchanged since it was written:

> **STATUS: PROPOSED. Not signed off. No implementation may start against it yet.**

It never became binding. `SPEC.md` §5.2 says it *"wins on shapes"*, but that sentence
describes a document that was never ratified, and §8 lists three things that had to be
signed off **before Phase 2 started** and never were. Phase 2 was then built to its own
design, and that design is the only implemented artifact: it runs, and 163 tests cover it.

⇒ **The Phase 3 client is built against the backend as it actually exists.** Phase 2 is
not reopened. `INTERFACES.md` should be amended to describe what was built, and that
amendment is a sign-off, not a code change.

⚠ The error envelope and the closed error-code enum (§1) **do** match the backend
exactly, so `SPEC.md` §6.2's eight UI states are unaffected by any of this. The client
still switches on `code` and never parses `message`.

### Category 1 — shape divergences. Amend the document; nothing is broken.

| Route / object | `INTERFACES.md` says | Backend actually does |
|---|---|---|
| `verify-code` body | `pin` | **`code`** |
| `force-login` body | `{otpToken, device}` | **`{otpToken, code, device}`** |
| `force-login` reply | `{session, revokedDevice}` | `{next, session}` — **no `revokedDevice`** |
| session object | `user{id,phone}`, `device{…}`, nested `subscription{status,serverTime,plan,entitlement}` | **flat**: `accessToken`, `accessExpiresAt`, `refreshToken`, `refreshExpiresAt`, `entitlement`, `subscriptionExpiresAt`. No user, no device, no plan, no status, no `serverTime` |
| membership | `GET /subscription/status` → status/expiresAt/serverTime/plan/entitlement | **`GET /membership`** → `{active, expiresAt}` only |
| payment start | `POST /payment/create` → `{paymentId, redirectUrl, amount, currencyUnit}` | **`POST /payment/start`** → `{paymentUrl, authority}` |
| logout | body `{refreshToken}` | **Bearer access token**, no body |
| `POST /auth/login` | a convenience alias | **does not exist** |
| `POST /analytics/event` | reinstated 2026-09-08 | **not a route.** Analytics is recorded server-side inside each handler; the app never posts an event |

**On `force-login` the backend is RIGHT and the document is wrong, not merely different.**
`INTERFACES.md` §3 shows `{otpToken, device}` with no code, which taken literally means
anyone who can call `/auth/send-code` for a number can evict that number's real device.
The backend re-verifies the code, and its own comment says why. Amend the document.

**`serverTime` is gone, and the client absorbs it without a backend change.** The
monotonic clock is seeded from the entitlement blob's `iat`, which is server truth at
signing time. ⚠ The cost, stated rather than implied: `iat` only arrives when a **new
blob** does, and a build with no entitlement key gets no server time at all and runs on
the wall-clock ratchet alone. It is not a full replacement for `serverTime`.

### Category 2 — a missing capability. This one is backend work and it blocks payment.

> **⚠⚠ A USER WHO NEEDS TO PAY CANNOT REACH THE PAYMENT ROUTE.**

Traced end to end, not inferred from one file:

1. `accounts/service.ts` `completeVerification` returns, for both "never subscribed" and
   "lapsed": `{ next: "PAYMENT_REQUIRED", userId }` — **no session, no token.**
2. `app.ts` `/auth/verify-code` forwards exactly that: `{next, userId}`.
3. `app.ts` `/payment/start` opens with `requireAuth(req, deps.tokens)`, i.e. a **Bearer
   access token**.
4. Nothing in between mints one.

So the only users who ever need to pay — new signups and lapsed renewals — hold a bare
`userId` and no credential, and every call to `/payment/start` from that state is a
`401 UNAUTHORIZED`. `INTERFACES.md`'s `signupToken` is precisely the thing that solves
this, and it was not built.

**It was never caught because `/payment/start` has no route test.** The only payment
assertion in `test/routes.test.ts` is that `verify-code` returns `PAYMENT_REQUIRED`; the
route behind it is never called. A green suite is not coverage of a path nobody exercises.

**Second, in the same category:** `INTERFACES.md` §7 requires the callback to
**302-redirect into the app** via `irallymeter://payment/callback`. The backend's
`handleCallback` returns `{ok, expiresAt}` as **JSON**. Consequence, stated as the user
would experience it: *after paying, the user is left looking at a JSON body in a mobile
browser, with no route back into the app.*

### What Phase 3 therefore delivers, and what it does not

- **Delivered in full:** phone entry, OTP, `DEVICE_CONFLICT`, Force Login, refresh with
  rotation, the launch gate, offline entitlement. That is seven of `SPEC.md` §6.2's eight
  states and every one of them is reachable and testable today.
- **Not delivered, deliberately:** the payment call itself, and §7's native deep-link
  plumbing (Android intent-filter, iOS `Info.plist` + `AppDelegate`). Building a client
  against a route it cannot authenticate to, or wiring a return path for a server that
  never redirects, would be scaffolding for a flow that cannot complete. The membership
  screen is built and states the block honestly instead of pretending.
- `url_launcher` is committed and currently **unused**; it is kept because the payment
  flow is deferred, not cancelled.

### How this closes

1. Amend `INTERFACES.md` to describe the built backend (category 1), and
2. decide the two backend items in category 2: mint a payment-scoped token for
   `PAYMENT_REQUIRED`, and make the callback redirect into the deep link.

Neither is Phase 3 work, and neither blocks anything above.
