# 0007 — Spec r3: a satisfiability amendment, and its authorisation

**Status:** amendment record · **Date:** 2026-08-23

## 1. Authorisation

jes, verbatim and complete:

> "okay it's possible the definition of bridge is mathematically impossible, we just need to do
> something sensible in every case, but not the impossible"

and, on being asked whether that extended to editing §6.6 itself rather than only to implementation
behaviour:

> "oh spec edit is allowed to make spec possible"

⭐ **The constraint is inside the sentence, not attached to it: edits that make the spec POSSIBLE.**
That authorises removing an impossibility. It does not authorise reshaping §6.6 more broadly, and
nothing below moves anything that was already satisfiable.

## 2. Artifacts and hashes

| revision | sha256 | state |
|---|---|---|
| r2 | `8765bb150fcc01c7dcba164b994d5a6fe407f2cc86e5f3f69289f326c8405c14` | **unchanged on disk** |
| r3 | `3f43be136bf9d037003b2ff6fd13e8c2ff5045b9fc77096b6128444a8bb28c5b` | this amendment |

⛔ **r2 is not edited in place.** It was filed byte-identical as jes wrote it, and the ability to
verify that is worth more than tidiness. r3 is a new file naming r2 in its header as superseded.
⚠️ r3 also carries **`Version: 0.1-draft-r3`**, because r1 and r2 were indistinguishable by header
and had to be told apart by hash — a trap this revision does not repeat.

## 3. Why in the spec rather than beside it

The impossibility is in what the spec *promises*, not in how this library behaves.
`docs/design/0006` could record that the promise cannot be kept, but the promise would still be
there for the next reader — and the next reader is whoever compares an implementation against a hash
someone else pinned. **A conformance claim against an unsatisfiable clause is not worth making.**

## 4. The six edits, and the impossibility each removes

**1 — the Bridge contract (§1) is now conditional on a bridge existing.**
It read *"Every valid edit over the supported Yjs data model … can be deterministically applied to
the other endpoint."* Measured: a document holding an item whose content is a nested type instance
can hold **no bridge at all**, so no edit authored on it can cross by any means. The old wording is
false for such documents under every implementation. ⇒ The precondition is stated, together with the
fact that it is **decidable in advance** — attempt the snapshot; it succeeds or returns
`:unsupported_content`.

**2 — new §6.11 defines the supported data model and bridgeability.**
r2 used *"supported Yjs data model"* five times and never defined it; §21 listed *"supported shared
types"* as a versioned property without requiring anyone to declare the set. So a reader could not
determine whether XML element children were in scope, while §10.2's observable-state list reads as
though they are. **The set is now a declared property of an algorithm version**, and a limit of that
kind MUST NOT be recorded as permanent.

**3 — invariant 5 is scoped to the endpoints of an existing bridge.** The same repair, at the
invariant.

**4 — §10.2 states the consequence, and splits the error.**
There is no partial bridge and no best-effort correspondence: the refusal is the whole behaviour
owed. And `:unsupported_content` MUST now distinguish a **caller-side** condition (remedy reported)
from a **version limit** (no remedy, because none exists). ⇒ Measured need: a locally-authored `Doc`
has an empty type registry and snapshots to nothing — one `apply_update/2` from success, previously
reported identically to a hard limit.

**5 — §10.5 states the tombstone case as impossible by construction.**
A snapshot mints live content only, so a source tombstone has **no item in the derived document to
be paired with — absent, not misplaced.** ⇒ Under this wording, an empty correspondence and the §17
re-authoring latch stop being exceptions and become **consequences**. An implementation MUST NOT
present the case as an unimplemented feature.

**6 — §28.2 gains fixtures 27 and 28**, so the weakening cannot become unfalsifiable. They are
appended rather than inserted, so no existing fixture number moves.

## 5. ⛔ The guard against "possible" becoming "unfalsifiable"

A correspondence clause weakened far enough to permit anything permits a **no-op translator** too.
That is not hypothetical here: **the totality corpus in `81ec1f0` was exactly that shape** — every
span an identity mapping, so a translator ignoring the bridge entirely would have passed all 120
cells, and it reported 100% green.

⇒ **Invariant 9 keeps its teeth by fixture, not by wording.** New mandatory fixture **27** requires a
non-degenerate correspondence; **28** requires a mislabelled crossing direction to re-author rather
than translate through the opposite side of the correspondence.

⚠️ Note that r2 **already** required *"mixed source client IDs"* (§28.1) — the existing requirement
my corpus violated. Fixture 27 states the reason, so the next reader does not have to rediscover it
by mutation.

## 6. Conformance after the amendment

`test/totality_test.exs` already satisfies 27 and 28, and the 260-cell matrix is unchanged by this
edit: **the same behaviour is now conforming rather than tolerated.** No library code changed.
