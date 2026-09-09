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
