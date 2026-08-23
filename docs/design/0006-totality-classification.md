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

13 document shapes × 10 edit kinds × **2 directions** = **260 cells**, each run end to end: snapshot →
attach bridge → author the edit on a replica → cross it → **apply the result to the destination**.

| outcome | cells |
|---|---|
| crossed, and verified at the destination | **220** |
| no bridge can exist (`:unsupported_content`) | **40** |
| unclassified (raise, untyped error, bytes the destination rejects) | **0** |

Invariant 6 — *"reorienting a bridge swaps presentation, not capability"* — is asserted directly as
well: no shape/edit pair crosses in one direction only.

⭐ **The verdict is the destination, not the byte count.** A cell counts as crossed only when the
crossed update, applied to the destination, leaves it holding the same identity-free observable
content as the edited source. Mutation testing confirms the check discriminates: withholding the
update from the destination turns **78 of the 100** red, and the 22 that stay green are exactly the
no-op edits, which change nothing at either end.

## 1a. ⛔ Two corpus defects that made the first version of this audit worthless

**Both were caught by mutation testing, and neither would have shown up as a failure.**

### The corpus was degenerate: every span was an identity mapping

The deterministic minter re-authors under the **smallest client id present in the source**. A
single-author document has exactly one — so the derived document reuses it, and every correspondence
span came out as `{100,0} → {100,0}`.

⛔ **With identity spans, a translator that ignored the bridge entirely and passed raw coordinates
through unchanged passes every cell.** That is precisely what invariant 9 forbids — *"missing
mappings are never guessed from visible position or raw numeric equality"* — and the matrix could
not have detected a violation of it. **120 cells of apparent rigour that a no-op would satisfy.**

⇒ Every shape is now **multi-author**, with a higher-numbered second author guaranteeing content
that must be remapped. A `single-author-degenerate` shape is **kept deliberately** — identity spans
are a real caller situation and must still be classified; they must simply never be the *only* case.
A dedicated test asserts the corpus contains at least one real remapping.

### The direction axis was decoration, because of the DATA rather than the axis

Mutation: mislabel `from:` on every crossing. **All 260 cells stayed green.** The cause was not that
the library ignores direction — it was that every edit anchored inside an identity-mapped span,
where a left lookup and a right lookup return the same coordinate.

Anchored in the **remapped** span (left `{200,0}` ↔ right `{100,5}`), direction is load-bearing:

| declared `from:` | mode | destination text |
|---|---|---|
| `:right` *(correct)* | **`:translated`** | `"hello!Z!"` |
| `:left` *(mislabelled)* | **`:reauthored`** | `"hello!Z!"` |

⭐ **This is invariant 10 behaving exactly as specified, and it is worth stating as its own result:
a mislabelled crossing does not silently translate through the wrong side of the correspondence and
does not corrupt the destination — it fails the strict preflight and re-authors.** The destination
still ends up with the right value; what is lost is authorship identity. ⇒ **"Something sensible" for
a caller error, not just for a hard case.**

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

## 4a. ⚠️ The verification itself was a representation comparison in disguise

The first `observable/1` listed each live **item's** content. The snapshot replay **consolidates
adjacent runs** — a source holding `"hello"` and `"!!"` as two items becomes one item `"hello!!"` —
so it reported **61 correct crossings as wrong**, every one of them the same consolidation.

⇒ Sequences are now flattened to their ordered **atomic values** in document order via
`get_sequence/2`, so item boundaries cannot be seen. ⭐ **A comparison that can see representation is
not a comparison of observable value**, however much it looks like one — and the failure direction
was the merciful one. The same mistake pointing the other way is a *silent pass*.

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
| never swap the endpoint docs for `:right` | **4 failures** |
| revert the corpus to single-author | **22 failures** (the degeneracy guard) |
| label both crossings `:right` in the direction test | **1 failure** |
| move the direction test's anchor back into the identity span | **1 failure** |
| *(restored)* | **0 failures** |

⚠️ The last one matters most: it proves the **anchor position** is load-bearing, so the test catches
the exact degeneracy that made the first version of this audit vacuous.

⚠️ The impossible set is asserted **by name**, not by count, and a separate test asserts the name
lists match the builder lists — because **a corpus that got smaller looks exactly like a corpus that
passed.**

## 6. Settled after the fact: the spec was amended

⭐ **jes answered: *"oh spec edit is allowed to make spec possible."*** ⇒ Spec **r3** now states the
Bridge contract conditionally on a bridge existing, defines the supported data model and
bridgeability (§6.11), and records the tombstone case as impossible **by construction** rather than
unpromised. `docs/design/0007-spec-r3-amendment.md` carries the authorisation, both hashes, and the
six edits.

⇒ **The 260 cells above did not change; their status did.** Fixture 19 and the §17 latch are
consequences of §10.5 rather than exceptions to it, and this library's behaviour is **conforming
rather than tolerated**.

⚠️ The authorisation was narrow — *edits that make the spec possible*. The remaining spec edits in
§9 of the rulings are not covered by it and stay open.
