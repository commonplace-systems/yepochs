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

### §28.1 compatibility fixtures — recreated in `test/compatibility_test.exs`

Read from `~/commonplace`'s own suites (explicitly not gated) and recreated against the span-based
API. Each `describe` names the §28.1 bullet it covers.

⭐ **Two places where "preserve the experimental behaviour" and "satisfy the spec" pull apart.** §27
makes three deliberate corrections, so the fixtures cannot all be preserved as-is — and the
differences are asserted rather than smoothed over:

1. **`inverse_derivation_map/1` has no bijection guard.** It flips `%{new => old}` pairs directly,
   so two new ids naming one old id lose an entry to a plain map-key collision — silently. The
   span model refuses to *construct* such a derivation at all (`:invalid_derivation`), which is
   §27.1's point. ⚠️ Whether the experimental map can actually reach that state depends on whether
   the replay can emit more items than the source holds; **I have not observed it**, so this is a
   latent hazard rather than a measured defect.
2. **`compose_dms([])` returns `%{}`** — an identity that silently succeeds. A bridge path has
   endpoints, so §14 requires at least one bridge and the empty path is a caller error.

**New coverage that had no equivalent anywhere in this repo: the real snapshot chain.** Two
successive *actual* snapshots, composed, with the assertion that an A-coordinate reaches a
C-coordinate holding the **same character** — not merely that the composition is non-empty. The
weak version (`spans != []`) passed against a mapping that could have been entirely wrong; the
character check is the one that means something.

⚠️ **Method note.** Three mutations were silent against the compatibility suite *alone* and redden
against the full suite. That is fine — a subset suite need not catch everything — but it is only
fine because it was **checked**: "my new tests pass" and "my new tests would notice" are different
claims, and the second is the one worth making.

---

## §22 / §29 audit — what an error-code census and a layout diff turned up

**Method:** enumerate every code §22 defines, count where each is *constructed*, and diff the actual
module tree against §29's suggested layout. Both are cheap and both found real work.

⚠️ **The census's own trap, recorded because it nearly produced phantom findings.** Four codes showed
**zero literal constructions**. Two were genuine gaps (§21, §15.1, since fixed). The other two —
`:missing_anchor`, `:missing_operation_target` — are raised **through a variable**
(`Error.new(first.code, …)`) and were fully implemented and tested. ⇒ ***A grep for "where is X
built" finds only the places X is built BY NAME. Indirection is invisible to it, and the absence it
reports is indistinguishable from a real gap.*** The same applied to `:invalid_epoch_ref`: one
literal construction, six call sites reaching it through `epoch_error/1`.

**Codes with few constructions turned out to mean two different things, and the difference is only
visible by reading:**

| code | one construction, but… |
|---|---|
| `:invalid_epoch_ref` | six paths reach it — indirection, **not** a gap. But two branches (invalid UTF-8, non-binary input) had **no test**; now they do. |
| `:unsupported_crossing_content` | reachable only when a plane **changes kind** between `before` and `edited` — a path with no test; now covered. |

### §29 layout diff

`lib/` matches §29 exactly, with one addition (`update.ex`, the decoded-update inventory) and **one
omission that mattered**: §29 lists `rebase/adapter.ex`, and §19.2 names
`Yepochs.Rebase.Adapter` as *the* mechanism by which an application supplies its own semantics.

⛔ **It did not exist, so that extension point was closed** — an application with a schema the three
Yjs planes cannot express had no way in, and the only alternatives were patching this library or
depending on it in the wrong direction. Now implemented: caller adapters are consulted **before** the
built-in planes, may deliberately override one for a type they own, and their errors propagate rather
than falling through to a generic diff that would discard exactly the knowledge the adapter exists to
apply.

⚠️ **Still divergent from §29, deliberately:** the built-in adapters live in `rebase.ex` rather than
in `rebase/{text,map,array,xml}.ex`. §29 is a *suggested* layout and §24 says the module split may
change; splitting three cohesive plane-diffs across four files would spread one dispatch decision
over five. **Recorded as a choice rather than an oversight** — the behaviour §19.2 actually requires
is present.

`test/` differs more: §29 suggests a `fixtures/` corpus of stored artifacts, and these tests build
their documents programmatically instead. ⚠️ **That is a real gap for cross-language conformance**
(§28.4 wants vectors applicable by both Yelixer and upstream Yjs, recording the versions that
generated them) — programmatic construction cannot pin bytes produced by a *different*
implementation.
