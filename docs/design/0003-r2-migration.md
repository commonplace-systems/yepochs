# 0003 — Migrating Tier 0 from spec r1 to r2

**Status:** done · **Date:** 2026-08-23

## ⛔ First: the two revisions are indistinguishable by header

Both say `Version: 0.1-draft` and `Date: 2026-08-22`. **Tell them apart by hash.**

| revision | path | sha256 | lines |
|---|---|---|---|
| r1 | `docs/proposals/2026-08-22-yepochs-spec.md` | `c24ce9dd…` | 1315 |
| **r2 (current)** | `docs/proposals/2026-08-23-yepochs-spec-r2.md` | `8765bb15…` | 1718 |

r1 is retained deliberately: it is what Tier 0 was originally built against, and deleting it would
destroy the provenance of the decisions in `0001` and `0002`.

## What actually changed for Tier 0

**One-directional translation became bilateral crossing, and a Bridge became a transducer.**

| r1 | r2 |
|---|---|
| `Span{target_*, source_*}` | `Span{left_*, right_*}` |
| stored direction `target/new -> source/old` | orientation `origin/old <-> derived/new` |
| sort by target client, target clock, … | **sort by LEFT client, left clock, …** |
| `Bridge{source_epoch, target_epoch, derivation, producer}` | `Bridge{left_epoch, right_epoch, correspondence, basis, receipts}` |
| `source_ref/2`, `target_ref/2` | `left_ref/2`, `right_ref/2` |
| `extend(bridge, Derivation.t())` | `extend(bridge, Bridge.Delta.t())` |
| — | new `Bridge.Basis`, `Bridge.Delta`, `Crossing.Receipt` |
| — | new algorithm `yepochs.cross` v1 |
| — | new error `:receipt_conflict`, `:missing_endpoint_state`, `:unsupported_crossing_content` |
| `:unsupported_update_feature` | `:unsupported_translation_feature` |

⭐ **The field mapping is a swap, not just a rename.** r1's `source_*` (old) is r2's `left_*`, and
r1's `target_*` (new) is r2's `right_*`. Confirmed against the §8.6 JSON example, where r1's
`{target_client: 17, target_clock: 4, source_client: 9, source_clock: 21}` becomes r2's
`{left_client: 9, left_clock: 21, right_client: 17, right_clock: 4}`.

⚠️ **Canonical order therefore changed.** r1 sorted target-first (new); r2 sorts left-first (old).
**The same logical derivation serializes to a different canonical span order across revisions** —
this is a wire-visible behavioural change, not a cosmetic rename.

### The semantic change that matters most

> **A missing coordinate mapping is no longer normally a failure.** It means the strict fast path
> cannot prove an exact translation, and the crossing must re-author the edit's observable effect at
> the destination (§1, §27.4).

`left_ref/2` and `right_ref/2` still return `:unmapped` — but `:unmapped` now **selects the crossing
fallback rather than proving an edit cannot cross**, and that is stated at both call sites.

Consequences already visible in Tier 0: `invert/1` must also exchange **basis roles** and **receipt
sides**; `compose/1` must stamp a `:composition` basis with **null** origin/derived roles and
**leave edge-specific receipts on their original bridges**; `extend/2` must accept a duplicate
receipt idempotently but reject one reference reused for a *different* result.

## ⭐ The migration validated the test suite, which is the part worth keeping

boss-clod's warning was that a suite which stays green across a spec change has not been validated
by that greenness — a test asserting r1's one-directional contract would keep passing while
asserting the wrong thing.

**Measured:** rewriting `span_test.exs` to r2 semantics produced **13 of 13 failures** against the
r1 implementation. The tests were genuinely coupled to r1's contract, not merely to its spelling.

All **9 mutations** were then re-run against the rewritten Bridge — including four new r2-specific
ones — and every one reddens:

| mutation | failures |
|---|---|
| lookup ignores span bounds | 8 |
| compose skips endpoint check | 2 |
| extend skips span-conflict check | 2 |
| compose omits re-offset into 2nd bridge | 4 |
| compose omits re-offset into 1st bridge | 6 |
| **invert does not flip basis** | 1 |
| **invert does not flip receipts** | 1 |
| **extend skips receipt-conflict check** | 1 |
| **compose carries receipts through** | 1 |

## What survived unchanged, and why that was worth designing for

**The interval algebra.** Partial-bijection validation, coalescing, intersection-based composition,
same-mapping-line extension — none of it changed, because none of it ever depended on which side was
called "source". Tier 0 being pure integer arithmetic with **no dependencies** is what made a
1,063-line spec revision a half-hour migration.

## Decisions taken locally, flagged as such

1. **Derivation wire key.** r2 §8.6 gives only a *bridge* example, using `"correspondence"`. A bare
   derivation's key is unspecified. `Derivation.to_map/1` emits `"spans"`; `Bridge.to_map/1` emits
   `"correspondence"`, matching the one concrete example the spec gives.
2. **`compose([single])` returns the bridge unchanged**, keeping its original basis, because nothing
   was composed.

## ⚠️ Standing caveat from jes on repo-boundary claims

> *"the specs could easily be confused about repo boundaries"*

⇒ **Every claim in these specs about which repo owns what is unverified until checked against the
tree.** The technical direction is authoritative; the repo attributions are not. Verified instance:
r2's §26-equivalent still says `CrossEpochMerge`/`Merger`/`SnapshotAncestry` "remain in
`commonplace-merkle-crdt`", but all three live in `~/commonplace`, and merkle-crdt's `lib/` has
**zero** references to them (control: that `lib/` holds 2 modules total, so the zero is real and not
a broken search).

⭐ **Operational rule:** when a spec says *"X remains in repo R"*, run one `command grep` against
R's tree before designing to it. Boundary claims are cheap to check and quietly go stale; **r2's are
new prose that never survived review in r1, so they carry less warrant, not more.**

---

## §28 conformance status, audited against the spec rather than from memory

r2 expands §28.2 from 15 mandatory fixtures to **26**. `test/conformance_test.exs` names them by
the spec's own numbering so coverage is auditable; fixtures already owned by a module's suite are
cross-referenced there rather than duplicated.

| fixtures | state |
|---|---|
| 1–6, 8–11, 14, 15, 18, 20, 24, 25 | ✅ covered in the owning module's suite |
| 7, 12, 13, 16, 17, 21, 22, 23 | ✅ added in `conformance_test.exs` |
| **19** | ⛔ **NOT satisfied** — see below |
| **26** | ⛔ **out of scope**, and argued rather than assumed |

### ⛔ Fixture 19 is a real gap and is pinned as one

§28.2(19) wants a re-authored crossing to return **non-identity correspondence spans**. §17 hedges
it — *"wherever the rebase adapter can prove that newly authored destination items correspond to
source items"* — and **0.1's adapters can prove none**: they re-author from an observable diff and
cannot say which destination item answers which source item.

⇒ A test pins the *current* behaviour (`correspondence.spans == []`) with a message telling the next
reader to update it when that changes. **Omitting the fixture would have let this file argue for
coverage it does not have**; a passing test that documents the gap cannot.

Consequence, already exercised by fixture 22: an edit that depends on a re-authored one has no
strict correspondence to use, so it re-authors too. That is what §17 means by *"any remaining
unmapped dependency simply selects re-authoring again"* — correct, but it means a chain of
re-authored edits never recovers strict translation until a fresh snapshot establishes one.

### Fixture 26 is out of scope, on the spec's own terms

"Destination admission through its own writer without adding another log writer" is a property of
the enclosing log protocol. §4 lists multi-writer admission as explicit non-scope and §29 requires
this package to run no process and own no storage. The test asserts the negative that *is* ours:
the application declares no callback module and registers no processes.

### §28.1 compatibility fixtures — outstanding

§28.1 requires moving or recreating commonplace's existing fixtures (deterministic snapshotting,
mixed top-level shared types, derivation-map inversion and composition, origin / right-origin /
ID-parent translation, mixed source client IDs, late-edit preflight, positional fallback,
cross-epoch translation inputs). ⚠️ **Not yet done.** Reading them is explicitly not gated, and
`~/commonplace` has ten relevant test files totalling ~1,430 lines. This is the largest remaining
piece of §30's acceptance criteria that is actionable without the hold lifting.
