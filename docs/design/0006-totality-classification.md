# 0006 — Totality: a defined behaviour or a demonstrated impossibility, in every case

**Status:** measured · **Date:** 2026-08-23
**Evidence:** `test/totality_test.exs` (123 tests), `test/unsupported_content_cause_test.exs`,
`probes/totality_matrix.exs`

## 0. What this responds to

> **jes:** *"okay it's possible the definition of bridge is mathematically impossible, we just need
> to do something sensible in every case, but not the impossible"*

⭐ **Read as method, that converts an impossibility into a requirement to CLASSIFY.** Every case owes
one of exactly two things:

1. a **defined sensible behaviour**, or
2. a **demonstration that it cannot be done**.

⚠️ **The second half is the one that decays.** A case that is genuinely impossible, and is only
*known* to be impossible in somebody's head, reads six months later as an unimplemented feature —
and the natural response to an unimplemented feature is to try to implement it. So each impossibility
below carries its mechanism, its exact boundary, and a test that fails if the impossibility is ever
*lifted*.

## 1. The matrix

12 document shapes × 10 edit kinds = **120 cells**, each run end to end: snapshot → attach bridge →
author the edit on a replica → cross it → **apply the result to the destination**.

| outcome | cells |
|---|---|
| crossed, and verified at the destination | **100** |
| no bridge can exist (`:unsupported_content`) | **20** |
| unclassified (raise, untyped error, bytes the destination rejects) | **0** |

⭐ **The verdict is the destination, not the byte count.** A cell counts as crossed only when the
crossed update, applied to the destination, leaves it holding the same identity-free observable
content as the edited source. Mutation testing confirms the check discriminates: withholding the
update from the destination turns **78 of the 100** red, and the 22 that stay green are exactly the
no-op edits, which change nothing at either end.

## 2. Impossible: an item whose content is a nested type instance

⛔ **A document holding a nested-type child cannot hold a bridge.**

The mechanism, measured:

```
source live items:      [{{:named, "e::children"}, nil, {:type, :xml_text}}]
after snapshot replay:  []
```

`Yelixer.Doc.snapshot_update/1` does not re-author items whose content is `{:type, _}`. The derived
document therefore cannot hold the source's observable content, **so there is no correspondence to
record and no bridge to attach.** This is refused with `:unsupported_content`, never silently
dropped — §10.2 requires exactly that.

⭐ **The boundary is exact, and narrower than "XML".** An XML element with **attributes** and no
children bridges fine — attributes are ordinary `{:any, _}` content under a `parent_sub`. Stating the
limit as "XML cannot bridge" would be wrong in both directions.

⚠️ **This is a SUBSTRATE limit, not a mathematical one.** It would be lifted by a replay that
re-authors nested types. `test/totality_test.exs` asserts the loss still happens, and **fails if it
stops** — so the day the substrate improves, the test says so rather than the list quietly staying
too long.

## 3. Mathematically impossible: a source tombstone has no counterpart to map to

This one is not a substrate limit and better engineering does not reach it.

A snapshot mints **live content only**. A source tombstone is a coordinate whose item is not in the
derived document *at all* — not misplaced, not renamed: absent. So there exists no destination
coordinate for a correspondence span to pair it with. ⇒ **No derivation over a snapshot of live
content can map source tombstones**, which is why §10.5 declines to promise it.

Two consequences follow, and both already have defined sensible behaviour:

- **Delete sets over historical tombstones** (`docs/design/0004`) — strict translation fails with
  `:missing_operation_target`, and the crossing re-authors. Ruling 3's **checked omission** narrows
  this: a historical delete range may be omitted, but only after three proofs, never on a raw
  coordinate comparison across epochs.
- **Re-authoring proves no correspondence** — so a re-authored delta cannot extend the bridge, and
  §17 latches: later edits depending on it re-author too. A document returns to identity-preserving
  translation only when a fresh snapshot re-establishes correspondence.

⇒ **"Sensible, not impossible" here means: the edit still crosses, and what is lost is authorship
identity — announced, not hidden.**

## 4. Defined but remediable: a doc whose registry does not describe its store

⭐ **Measured while building the matrix, and it invalidated the first run of it.** A locally-authored
`Doc` — items in `client_pending`, never round-tripped — has an **empty type registry**. The replay
iterates that registry, so:

```
content: "hello"   types: []   snapshot_update: 2 bytes (empty)
```

The §10.2 guard catches it and refuses. **The refusal is correct; it was not sensible.** It reported
the same `:unsupported_content` as the hard limit in §2, so a caller one `apply_update/2` away from
success could not tell their case from one with no remedy at all.

⇒ `:unsupported_content` now carries a **`cause`**:

| cause | meaning | remedy |
|---|---|---|
| `:unregistered_types` | the registry does not describe the store | reported in the error: round-trip through `apply_update/2` |
| `:nested_type_children` | §2's hard limit | **none, and none is offered** |

⚠️ Nested-type content is checked **first**: a doc can be in both states, and offering the remedy to
a doc that also holds an unbridgeable child sends the caller round a round-trip that cannot help.
Mutation testing caught that ordering asserted **nowhere** — swapping the branches left every test
green, because no case held both conditions. There is now one that does.

## 5. Why this is a test and not a note

⭐ **A filed artifact fires; a remembered rule does not.** The classification is `test/totality_test.exs`,
so a change that introduces an unclassified cell fails the suite rather than being noticed later.

Demonstrated able to go red, and green on known-good input:

| mutation | result |
|---|---|
| drop `xmlfragment-child` from the impossible list | **10 failures** |
| destination never receives the crossed update | **78 failures** |
| drop one shape from the compile-time name list | **1 failure** (the corpus-drift guard) |
| claim the nested-type child survives the replay | **1 failure** |
| *(restored)* | **0 failures** |

⚠️ The impossible set is asserted **by name**, not by count, and a separate test asserts the name
lists match the builder lists — because **a corpus that got smaller looks exactly like a corpus that
passed.**

## 6. What this does NOT settle

⛔ **Whether jes's sentence is about §6.6's definition of a bridge itself** — i.e. whether the spec
should weaken "a monotonically growing correspondence" — **is his to say, and is not decided here.**
This document classifies what the implementation can and cannot do. If the definition is to change,
that is a spec edit, and this repo does not own the spec.
