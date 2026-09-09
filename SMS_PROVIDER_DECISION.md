# SMS_PROVIDER_DECISION.md

**Phase 1 deliverable. Researched 2026-09-08. This is a recommendation, not a decision.**

> Saam's gate, verbatim: *"Do not present a provider as confirmed-working on the basis of
> marketing copy. Mark unverified claims as unverified. **I will approve the choice before
> you build against it.**"*
>
> **Nothing is built against any provider until that approval lands.** Phases 2-6 are stopped.

Every claim below is tagged. `[VENDOR CLAIM ONLY]` = read from that vendor's own docs, not
independently corroborated. `[SINGLE SOURCE]` = one non-vendor source. `[UNCLEAR]` = could
not be resolved. Untagged = converged across two or more independently fetched pages.

---

## 1. The three findings that actually matter

### 1.1 The international providers are out, and it is not a coverage gap — it is policy

| Provider | Verdict | Evidence |
|---|---|---|
| **Twilio** | **NO.** Delivery to Iran discontinued **2025-03-15**. | Twilio's own "Iran: SMS Guidelines" page states delivery is blocked and **cannot be overridden by Geo Permissions**. Corroborated by its own error codes 21408 / 60605 / 63058. |
| **AWS SNS** | **NO.** | AWS's own supported-countries table was **enumerated directly, not summarised**: the "I" section runs Iceland → India → Indonesia → **Iraq** → Ireland. **Iran is absent.** Corroborated by an AWS re:Post article naming Cuba, Iran, North Korea, Syria, Sudan as sanctions-excluded. |
| **Infobip** | **Not usable self-serve.** | Its coverage docs list Iran as reachable, but only via enterprise sender-ID registration (company name, website, volume, ~3-day approval). A separate Infobip support page **excludes Iran from self-sign-up entirely.** Both pages are Infobip's own `[VENDOR CLAIM ONLY]`. |
| **Vonage** | **Very likely no.** | Its own restrictions page returned **HTTP 403 to automated fetch, twice.** Search snippets of that same page say P2P to Iran is prohibited and "Iran registrations are currently on hold until further notice" (July 2025). **Whether A2P/OTP specifically still works is `[UNCLEAR]`.** |
| **Bird / MessageBird** | **`[UNCLEAR]`, historically restricted.** | An older restrictions page says Iran "requires registration", is MCI-only (43211), and that non-RighTel networks **overwrite the sender ID** — partial and unreliable even before 2025. Current page redirected on fetch. `[SINGLE SOURCE, POSSIBLY STALE]` |

**⇒ Domestic Iranian providers are the only real candidates. This is the reason, and it is
documented by the vendors themselves, not inferred.**

### 1.2 ⚠⚠ Every Iranian provider is model (b). This decides the schema.

The brief asked whether the provider generates **and verifies** the PIN server-side (Twilio
Verify shape, model **a**) or only sends a message we compose (model **b**).

**Confirmed model (b) from four independent official docs pages** — Kavenegar, SMS.ir,
Ghasedak, Melipayamak — all showing the same shape: the caller supplies the code
(`token` / `code` / `param1`) into a pre-registered `template` / `templateId` /
`templateName`. **No provider examined offers a Verify-style service.**

**Consequences for the build, and they are not small:**

1. **The `otp_codes` table is required.** The backend generates the code, **hashes it**
   (never plaintext), stores it with a TTL and an attempt counter, and verifies it itself.
2. **`OtpSession` as currently modelled in `irallymeter-api` was shaped for the proxy case**
   (it holds a provider handle so the provider's own id never reaches the client). It needs
   revisiting: it becomes the hashed-code table, and the partial index
   `otp_sessions_one_live_per_phone` still applies.
3. **`verifyCode(handle, code)` in the abstraction does real work** instead of proxying.
   The interface in `SPEC.md` §5.7 does not change — which is the point of having it.
4. **Every provider requires a pre-approved message template ("pattern" / الگو), and not
   one of them publishes an approval SLA.** Faraz SMS is the only one that even names the
   step (a "monitoring unit", واحد مانیتورینگ, notifying by SMS). **Template approval is
   therefore an unbounded item on the critical path** — which is what makes finding 1.3
   below the deciding factor rather than a nice-to-have.

### 1.3 ⚠ Onboarding — **RESOLVED 2026-09-08, NOT A BLOCKER. Kept for the record.**

> **Saam, 2026-09-08:** *"why does it matter who owns the sms.ir we are building it for a
> client they will give us the api key and the phonenumber"*

**The account is the client's.** They hold the SMS.ir panel, they do the national-ID
onboarding, and they hand over the API key, the template id and the line number. Every
requirement below is therefore theirs and already satisfied on their side. It is recorded
because it was raised as the headline finding and a future reader would otherwise re-raise
it. **Do not re-open this.**

The original text follows unchanged.

Four providers' own docs (SMS.ir, Melipayamak, Farapayamak, IPPanel) **independently
converge** on the same requirement: an **Iranian national ID (کد ملی)** photo, plus a mobile
number **registered under that same national ID**, plus — for withdrawals and dedicated
lines — a **Shetab bank card in the same name**. Melipayamak additionally requires a
selfie-with-ID.

**No provider examined states a path for a non-Iranian entity with no Iranian national ID to
self-register. None was found to explicitly refuse one either.** That gap is a question for
the vendor's sales desk, not something public docs can answer.

**⇒ This reorders the whole matrix.** If Amirali's side holds the account, everything below
stands. If it has to be held from outside Iran, the ranking is moot and the real question
becomes which vendor will talk to a foreign entity at all.

---

## 2. Comparison matrix

| Provider | REST API | OTP model | Pattern + sandbox | Onboarding | Pricing | Limits / webhooks | Docs + Node SDK |
|---|---|---|---|---|---|---|---|
| **SMS.ir** | `https://api.sms.ir/v1`, `POST /send/verify`, header `x-api-key` — read off the vendor page | **(b)** `parameters:[{name:"Code",value:"12345"}]` into a `templateId` | Template required. **SANDBOX CONFIRMED**: sandbox key + default template `123456` (`"کد تائید شما: #CODE#"`) works before your own template clears `[VENDOR CLAIM ONLY, but concrete]` | National ID + phone registered to it; ID-card photo `[VENDOR CLAIM ONLY]` | Not confirmed | `429` documented; threshold not published; webhook not confirmed | Persian docs + Python/.NET SDKs. **No official Node SDK.** Third-party npm exists `[SINGLE SOURCE each]` |
| **Kavenegar** | `api.kavenegar.com/v1`, `VerifyLookup` `[VENDOR CLAIM ONLY]` | **(b)** `VerifyLookup({receptor, token, template})` — `token` is **our** code | Template required. **No sandbox found**; approval lead time not documented | **Not verified for Kavenegar specifically** | 50,000 Rial signup credit `[VENDOR CLAIM ONLY]`; per-SMS not confirmed | 200 msgs/call, 900 chars `[VENDOR CLAIM ONLY]`; webhooks not confirmed | **Best-documented of the eight** (real English + Persian references) and the **only OFFICIAL vendor-maintained Node SDK** (`kavenegar-node`, Kavenegar's own GitHub org) |
| **Ghasedak** | `gateway.ghasedak.me/rest/api/v1/WebService/SendOtpWithParams` | **(b)** `param1..param10` | `templateName` required; approval + sandbox not documented | Not documented | ~141 Toman/msg in a 400k–1.5M tier `[SINGLE SOURCE]` | Not documented | Official SDKs incl. Node — **but Snyk flags `ghasedak-node` inactive, 0 weekly downloads, 2 known vulns** `[SINGLE SOURCE: Snyk]` ⇒ effectively unmaintained |
| **Melipayamak** | `POST rest.payamak-panel.com/api/SendSMS/SendOtp` | **(b)** `code` documented as a mandatory int | Pattern ("پترن") service documented; lead time + sandbox not documented | National ID + phone in one name, ID photo **+ selfie**, **Shetab card** for withdrawal `[VENDOR CLAIM ONLY, own FAQ]` | Volume-tiered; custom above 300k/mo | Not documented | Persian docs; third-party Node packages only |
| **Farapayamak** | Base `rest.payamak-panel.com` — **the identical domain as Melipayamak's OTP endpoint** | **`[UNCLEAR]`** — inferred (b) from the shared domain, **not confirmed for this brand** | "وبسرویس خدماتی (الگو)" documented; no lead time | ID-card photo + selfie `[VENDOR CLAIM ONLY]` | Not confirmed | Not confirmed | Docs portal exists; no Node SDK found |
| **IPPanel** | `docs.ippanel.com` / `edge.ippanel.com` — **both returned HTTP 502 on direct fetch, twice** | Pattern-based, **not confirmed via a working docs page** | Pattern required per third-party guides `[SINGLE SOURCE]` | National ID + phone in owner's name + postal address `[SINGLE SOURCE]` | Not confirmed; **white-labelled to many resellers with no uniform pricing** | Not confirmed | **Official docs unreachable during research** — itself a docs-quality finding. PHP SDK only |
| **Faraz SMS** | `farazsms.com/api/`, `/api/send-sms-with-pattern-mode/` | Pattern params; code-generation side **not explicitly stated** `[UNCLEAR]` | **The only vendor documenting the human review step** ("واحد مانیتورینگ"), still **no SLA** | Not documented | Not confirmed | Not confirmed | **The only TypeScript-native SDK found across all eight** — `aspian-io/faraz-sms-sdk`, but **third-party, not the vendor's** `[SINGLE SOURCE]` |
| **Raygan SMS** | `raygansms.com/SendMessageWithUrl.ashx` `[SINGLE SOURCE: a working gist]` | **UNRESOLVED.** A third-party Laravel package mentions `sendAuthCode()` **and** `checkAuthCode()`, which would make it the market's only model (a) — **could not be confirmed**; the working sample shows only a plain send `[SINGLE SOURCE, UNCONFIRMED]` | Not documented | Not documented | Not documented | Not documented | **Thinnest docs of the eight.** No official API reference found |

### ⚠ A structural finding the matrix cannot show

Farapayamak's documented base URL and Melipayamak's documented OTP endpoint are **the same
domain** (`rest.payamak-panel.com`), observed independently on each vendor's own docs.
Separately, third-party guides describe IPPanel as white-labelled under several reseller
brands (Taban, Max SMS, Modir Payamak, Mediana), and **Faraz SMS's own registration page
redirects to an IPPanel domain** (`panel.iranpayamak.com`).

**⇒ These eight are probably not eight independent platforms.** At least two clusters appear
to share infrastructure. Neither vendor states this, so it is a **hypothesis, not a
finding** — but it matters if you ever want a second provider as genuine failover, because
two brands on one backend fail together. **Ask each vendor point-blank who operates their
backend before treating any two as redundant.**

---

## 3. Recommendation

### Primary: **SMS.ir**

It is the **only provider examined with a confirmed working sandbox** — a sandbox API key
plus a default template (`123456`) that lets the whole OTP integration be built and tested
**before your own template clears approval**. In a market where every provider requires
pre-approval and **not one publishes an SLA**, that removes the single largest schedule risk
in the entire phase. The REST shape is clean and directly documented, and model (b) is
unambiguous from the vendor's own example.

**Cost of choosing it:** no official Node SDK. We write a thin `fetch` wrapper ourselves,
which is a handful of lines against a simple REST endpoint and is **better than depending on
an abandoned third-party package** for the auth path.

**⚠ CORRECTION 2026-09-08, measured against the npm registry rather than search results.**
This report listed `@cryptommer/smsir`, `sms-typescript` and `sms-ir-nodejs` as SMS.ir Node
packages. Checked directly:
- `sms-ir-nodejs` **does not exist on npm** (404).
- `@cryptommer/smsir` exists but was **last published 2022-04-05 with 4 weekly downloads** —
  abandoned, and not something to put on an authentication path.
- **`sms-typescript` is NOT an SMS.ir client at all.** Its repository is
  `IPeCompany/SmsPanelV2.TypeScript`, i.e. **IPPanel** — a different vendor in this same
  matrix. It was filed under the wrong provider here.
⇒ **There is no maintained SMS.ir Node client.** The adapter calls the documented REST
endpoint directly, which is the decision already implemented in `irallymeter-api`.

### Runner-up: **Kavenegar**

Best-documented API of the eight (a genuine English reference alongside the Persian one) and
the **only one with an official vendor-maintained Node SDK**. Its `VerifyLookup` model is
unambiguous. **The reason it is second and not first: no sandbox was found**, so template
approval sits on the critical path with no documented way to test around it.

### Do not use

- **Raygan SMS** — thinnest docs, no official API reference, and its OTP model is genuinely
  unresolved. For a purchase decision that is a risk flag, not an inconvenience.
- **`ghasedak-node`** — Snyk: inactive, 0 weekly downloads, 2 known vulnerabilities. If
  Ghasedak is ever chosen, call the REST API directly and never the abandoned wrapper.
- **IPPanel** — its own docs were unreachable (502) twice during this research, and it sits
  at the centre of the reseller/white-label question above.

**Whichever is chosen, the schema conclusion is the same:** model (b) across the whole
market, so we generate, hash, TTL, count attempts and verify server-side ourselves.

---

## 4. COULD NOT BE VERIFIED FROM PUBLIC SOURCES

Listed because the brief requires unverified things to be marked, not buried.

- **Template approval turnaround (SLA) for every single provider.** Nobody publishes hours
  or days. Faraz alone even names the review step.
- **Comparable per-SMS pricing.** Only fragments: Ghasedak ~141 Toman/msg in one tier
  `[SINGLE SOURCE]`, Kavenegar's signup credit. **No comparable price list was confirmed for
  SMS.ir, Farapayamak, IPPanel, Faraz or Raygan.**
- **Documented rate limits** for anyone except Kavenegar (200/call, 900 chars) and SMS.ir
  (a `429` exists; the threshold is not published).
- **Delivery-status webhooks for any of the eight.** Ghasedak documents a poll-based
  `GetStatus`; **no push webhook was confirmed anywhere.** Plan for polling, not callbacks.
- **Whether a non-Iranian entity can open and pay for an account at all — at any of them.**
  This is §1.3 and it is the most decision-relevant gap in the whole document.
- **Vonage's and Bird's current A2P/OTP-specific posture** — both primary pages blocked
  automated fetch (403 / redirect).
- **IPPanel's actual API reference** — 502 on repeated attempts; everything reported about
  it comes from third parties.
- **Whether Farapayamak / Melipayamak / IPPanel share ownership** — flagged from a shared
  domain and reseller descriptions; **no corporate record was found either way.**
- **Raygan's actual OTP model** — the `sendAuthCode()`/`checkAuthCode()` pair would be the
  one case of model (a). Treat as unresolved, **not as a finding.**

---

## 5. What I need from you before Phase 2 starts

1. **Approve a provider** (or reject both and say why). This is the gate.
2. ~~**Who owns the SMS account?**~~ **ANSWERED 2026-09-08: the client's.** They provide the
   API key, template id and line number. §1.3. Closed.
3. Optional but cheap: if you or Amirali can ask the chosen vendor **two questions directly**
   — the real template-approval turnaround, and whether they offer a delivery webhook — that
   closes the two gaps public docs could not.

---

## 6. Sources

41 sources, all accessed **2026-09-08**. Primary vendor documentation and policy pages were
preferred over summaries throughout; where a page could not be fetched, that is stated in
the row rather than filled in from a search snippet as though it had been read.

Vendor docs: kavenegar.com/rest.html · kavenegar.github.io/kavenegar_en · github.com/kavenegar/kavenegar-node ·
sms.ir/rest-api · ghasedak.me/docs · doc.ghasedak.me · melipayamak.com/api · melipayamak.com/api/sendotp ·
melipayamak.com/faq · docs.farapayamak.ir · farazsms.com/api · farazsms.com/api/send-sms-with-pattern-mode ·
raygansms.com · docs.kerasno.com/ippanel `[3rd party]` · modirpayamak.com/ippanel `[3rd party]` ·
snyk.io/advisor/npm-package/ghasedak-node · github.com/aspian-io/faraz-sms-sdk `[3rd party]`

Sanctions / coverage: twilio.com/en-us/guidelines/ir/sms · twilio.com/docs/api/errors/{21408,60605,63058} ·
twilio.com/en-us/legal/service-country-specific-terms · docs.aws.amazon.com/sns/latest/dg/sns-supported-regions-countries.html
(enumerated directly) · repost.aws/knowledge-center/sns-text-messages-fail-to-deliver ·
infobip.com/docs/essentials/getting-started/sms-coverage-and-connectivity ·
support.infobip.com/what-are-the-regulations-for-specific-countries ·
api.support.vonage.com (403, snippet only) · messagebird-support-center… · docs.bird.com (redirected)
