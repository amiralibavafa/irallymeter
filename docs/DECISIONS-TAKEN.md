# Decisions taken on Amirali's behalf

Amirali answered the open questions with **"do whatever you think is more
professional."** This file records exactly what that was read to cover, what was
decided, and what was deliberately left alone.

Every decision below is reversible and each one names what would reverse it.
Nothing here is buried in a commit message only.

---

## What the delegation was NOT read to cover

Four of the ten questions are not craft calls. Taste cannot answer them, and
treating a blanket "you decide" as authority over them would be helping myself
to a decision that needs Amirali's knowledge of his own market.

| # | Left open | Why it is not mine |
|---|---|---|
| B2 | Map tile source | The OSMF policy **prohibits** the pre-seeding the existing `FileTileProvider` TODO plans, so this is a licensing constraint before it is a preference. Someone has to pick a provider and accept its terms. |
| B3 | Persian-Indic digits vs Latin numerals | For Iranian crews **the digits are the product**. Rally road books are conventionally Latin, but that is a claim about what crews expect, and he knows and I do not. |
| B5 | iOS posture | Third-party Iranian iOS stores re-sign the binary and Apple revokes those certificates, which kills **every installed copy at once**. That is a business risk to accept, not a technical one to solve. |
| B8 | Signing key ownership | Whose key, held where. Custody question. Also urgent: an app first installed under the debug key **cannot be updated with a real one without uninstalling**, which wipes every tester's trips, so it has to be settled before testers accumulate data worth keeping. |

---

## The six decisions taken

### A1 — the ±25 % clamp SATURATES. **Kept.**

The literal reading of §12.2 ("ignore it and hold v₀") was built first and my own
test caught it **sawtoothing**: the estimate climbs to 25, snaps back to 20,
climbs again, settles at 22. On a driver-facing speed readout an oscillation
like that reads as a fault. Saturating at the ceiling is also the plain meaning
of the word "clamp".

**Reverses if:** Amirali intended the snap-back literally, in which case the
sawtooth is a deliberate signal rather than a defect.

### A2 — the ±25 % bound applies UPWARDS ONLY. **Kept.**

Applied symmetrically it would hold a car braking to a halt at v₀ and invent
distance it never travelled. Amirali's own `tunnel_system_test` 11 already
asserts the estimate must settle at a clean stop, so the symmetric reading
contradicts a test he wrote.

The risk is also asymmetric, which is the deciding argument: an **over-estimate
is permanent**, because the engine reconciles undershoot only, while an
under-estimate recovers on the very next fix.

**Reverses if:** the road test shows deceleration being tracked too aggressively.

### B1 — portrait keeps the two-row top bar. **Kept.**

The bar overflowed by **142 px** in portrait, and grew to 137 px of overflow in
Estimation Mode as the status text lengthened. Amirali's own skipped test
recorded exactly that number. Every one-row fix costs something real: shrinking
glove-sized touch targets, ellipsising the trust indicator, or hiding navigation
behind a menu tap while moving.

Stacking the five nav icons on their own row costs **~56 px of a dimension that
has 1038**, and the targets end up further apart than before. Landscape is
untouched. Verified on device in both orientations.

**Reverses if:** he would rather portrait dropped a feature than gained a row.

### B4 — the MOVING average is now built. **Changed.**

§8 names two averages and requires the app to make clear which is displayed.
Only the overall one existed. The `AVG (ALL)` label answered the ambiguity but
not the requirement, so the second average now exists.

The two share a numerator and differ only in the denominator. **"Moving" is
defined by the distance engine, not by a speed threshold of our own** — a delta
carrying no distance is a stop. That reuses the min-movement floor and accuracy
gating already applied in `GpsDistanceSource`, so the two averages cannot
disagree about what counts as movement, which a second independent threshold
would eventually let them do.

It rides as a small `MOVING` line inside the existing tile rather than taking a
sixth grid slot, because the trip panel is already tight in portrait.

It was labelled `MOV` for about ten minutes, and the first person to see it asked
what it meant — which is §8's exact failure mode reproduced in miniature. Now
spelled out with its unit.

**Reverses if:** he wants it as its own tile, or not at all.

### B6 — `minSdk = 23` and iOS 12.0 both stay. **Kept.**

Older handsets are common in the target market and raising either floor drops
them. Note that Flutter's Android migrator **rewrites `minSdk` on every native
build** and has to be reverted each time; this happened again while preparing
the test build.

**Reverses if:** a dependency requires a higher floor, which is the only thing
that should force it.

### B7 — a Settings row to grant location. **Added.**

A denied permission had **no way back**. The rationale screen shows once and
never again, so tapping DON'T ALLOW by accident left the app permanently dead: a
trip counter that silently never moves, with nothing on screen saying why.

The rejected alternative was re-showing the rationale whenever location is
missing, which nags the person who denied on purpose. A row they have to come
and find does neither.

Android distinguishes *denied* (askable) from *denied forever* (only the system
settings page can undo it), so the row checks first and routes to the right place
instead of firing a request the OS would silently swallow. Location switched off
device-wide is a third state again, and opens location settings rather than app
settings, because no app-level grant helps there.

**Reverses if:** he considers the extra Settings section clutter.

---

## Two more, found by Saam using the app rather than reading it

Neither was on the question list. Both are recorded here because they were
decided the same way.

**The countdown target was not adjustable.** `setCountdownTarget` has existed on
the controller since the initial commit and **nothing ever called it**, so the
countdown was frozen at its 1:00 default and the mode was really a fixed
one-minute timer wearing a countdown label. The gap was invisible from the code,
because the method is there and looks wired.

Stepped buttons rather than a wheel picker, because this is used in a moving car
with gloves on. Steps are what a road book uses: minutes for the start interval,
ten seconds to trim it. Clamped to a 10 s floor so the target can never reach
zero and finish the instant it starts, and locked while running, because moving
the finish line under a crew already counting down to it is worse than making
them stop first.

**The map background was flutter_map's default light grey** in an app whose whole
palette is built for driving at night.

---

## One question this raised, deliberately NOT decided

**B9 — route recording / GPX in v1.** Saam asked whether the recording was
needed. The thing he was looking at was a defect of ours (a REC light on a cold
launch, fixed in `[SA-V2 18]`), but the underlying question is real: the spec
lists GPX import as a *possible future* feature, and the code is 380 lines of
Amirali's, untouched by this branch.

It was **not** removed. Deleting a working feature the owner wrote is the same
category as the four left open above — a product call, not a craft one. Added to
`docs/QUESTIONS-FOR-AMIRALI.md` with a recommendation to keep.

## Status

`SA-V2`, **322 pass / 1 skip / 0 fail**, `flutter analyze` at its 2 pre-existing
issues. The one skip is `road_scenarios_test` 12 (urban canyon, −12.50 %),
asserted at full strength and never weakened.

Nothing here changes the three things that still need a car rather than more
code: the road test, the GPS OFF→ON recovery on real hardware, and the urban
canyon figure.
