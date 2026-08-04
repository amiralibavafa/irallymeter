# PHASE 3 — WHAT IS DONE, AND WHAT IT TAKES TO CALL IT COMPLETE

Branch `SA-V1` @ `9ccef1c` · **295 pass / 3 skip / 0 fail** · `flutter analyze` 2 pre-existing.

**Status: SOFTWARE-COMPLETE.** Every requirement that can be implemented and
verified without a car, an iPhone, or a decision from Amirali is done. This
document is the checklist that turns that into **COMPLETE**.

It is deliberately not called "done". I said that once already and then found
three more real bugs (`[3.16]`, `[3.17]`, `[3.18]`).

---

## 1. Done and verified in software

| Requirement | Where |
|---|---|
| §5.1 measurement state indicator | amber digits + `EST`/`EST?`/`SYNC` on all four readouts |
| §6.1 noise gating, 4 rules | `[3.2]`, `[3.4d]`, **`[3.16]`** |
| §7.1 Doppler first, differentiation fallback | `[3.1]` |
| §7.2 display smoothing ≤ 1 s latency | `[3.7]` — time-based, not per-sample |
| §8 which average is shown | `[3.8]` — labelled `AVG (ALL)` |
| §9 Trip 1 / Trip 2 independent | pre-existing + `[3.17]` |
| §12.1 speed-hold dead reckoning | pre-existing |
| §12.2 ±25 % accelerometer refinement | `[3.3]`, first run in a full replay in `[3.9]` |
| §12.3 confidence decay 60 s / 180 s | `[3.5]` — seen red on device at 400 s |
| §14 manual correction removed | `[3.4b]` — `lib/features/tunnel/` deleted |
| §15.1 / §15.2 automatic entry and exit | `[3.4a]` — three consecutive consistent fixes |
| §15.3 automatic section logging **+ screen** | `[3.4c]` + **`[3.17]`** |
| §16.1 invisible correction, never backwards | `[3.5]`, `[3.13]`, `[3.17]` |
| §16.2 estimated state visible | `[3.5]` |
| §17 pure-Dart engine | asserted **structurally** in `[3.17]` |
| §18.2 platform settings | `[3.6]` — iOS had never been configured at all |
| §19 rows 1–5 | `T1`–`T8d` |
| §19 row 6 | **measurable as of `[3.18]`** — see §3 |
| §20.1 record and replay + debug player | `[3.0]`, `[3.10]` |

**~95 scenario tests:** 22 tunnel-hardening · 18 general · 15 road · 9
completeness · 7 long-tunnel · 7 GNSS health · plus the §19 targets.

---

## 2. Known limitations, measured and accepted

| | Number | Status |
|---|---|---|
| Chord shortening on hairpins | −0.76 % | Inside §19's 1 %. §19 defers a calibration factor; not needed at this geometry. |
| Urban canyon | **−12.50 %** | Estimation Mode coasts at v₀ when accuracy breathes past the integrable limit. One test **skipped at full strength** — do not weaken it. |
| §8 moving average | not built | Saam chose overall-only-but-labelled. A decision, not a gap. |
| Compass tilt compensation | not fixed | Heading wanders under acceleration. `PHASE4-AUDIT.md` P12. |

---

## 3. WHAT NEEDS A REAL DRIVE — the sign-off checklist

Run `docs/ROAD-TEST.md`. Every item below has somewhere to read the answer, so
this produces **numbers, not impressions**. Open **Settings → Section log** for
the GNSS HEALTH panel.

| # | Test | Where to read it | Passes when |
|---|---|---|---|
| **1** | **Toggle location OFF for a minute mid-drive, then ON. Do not restart the app.** | Cluster + `STREAM STALLS` | Badge clears within ~20 s and the trip counter advances again. **This is the one unproven fix — if it fails, Phase 3 reopens.** |
| **2** | Drive a real tunnel (Niayesh 6 658 m or Alborz 6 400 m) | Section log entry | Distance within ~3 % of the signed length; no jump and no reversal on exit; `EST` amber, and `EST?` red past 3 min |
| 3 | Same tunnel | `STREAM STALLS` | **Still 0.** `[3.15]` guarantees a tunnel never tears the subscription down |
| 4 | Any 20+ minute drive | `SUSTAINED Hz` | **≥ 1.00 Hz → §19 row 6 PASS.** Also check it with the screen off |
| 5 | Measured 50 km against markers | Trip A | Error ≤ 1.0 % (§19 row 1) |
| 6 | A city section in traffic and between tall buildings | Trip A vs known distance | Report the real % — replay says −12.5 % worst case, and **that number decides whether §6.1 gets revisited** |
| 7 | A twisty road against a known distance | Trip A | Report the % — decides whether §19's calibration factor is needed |
| 8 | Compass: "Use true north" on, drive above 18 km/h | Heading source | Should switch `MAG` → `TRUE` within ~20 s. Does the needle still feel laggy? Does it wander when cornering? (that last one is known, P12) |
| 9 | Screen off, in the mount, long drive | Trip still counting | Foreground service survived (§18.4, §20.3) |
| 10 | Android battery optimisation ON, same drive | Trip still counting | The one platform issue that cannot be solved in code |
| 11 | Fresh install | App boots | Watch for a hang on the Flutter logo — that is `P1`, an intermittent race |
| 12 | iOS | Anything at all | **Nobody has ever run this app on iOS.** It builds for the simulator only |

---

## 4. Phase 3 is COMPLETE when

1. **Item 1 passes.** The trip counter must recover from a location toggle
   without an app restart. This is the only outstanding item that can reopen
   Phase 3 rather than becoming a Phase 4 ticket.
2. **Items 2, 3 and 4 pass** — a real tunnel measured within 3 %, zero stream
   stalls, and ≥ 1 Hz sustained.
3. **Item 5 passes** — 50 km within 1 %.
4. **Items 6 and 7 are reported as numbers**, whatever they are. They do not
   have to pass; they have to be measured, because they are the inputs to the
   §6.1 and calibration-factor decisions.
5. **Amirali rules on the two §12.2 calls** — saturate-vs-snap-back, and
   upwards-only. Neither blocks anything; both are deviations from a literal
   reading that were flagged rather than hidden.

Items 8–12 are real work but belong to Phase 4 and the platform backlog, not to
Phase 3 sign-off.

---

## 5. If something fails

Send the number and a screenshot of the section log. The two failures that
matter most are a **frozen trip counter that does not recover** (item 1) and any
**visible jump or reversal** on tunnel exit (item 2) — both are stop-ship, and
both reopen this phase rather than moving to the backlog.
