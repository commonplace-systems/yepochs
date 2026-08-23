# Open questions

**For:** jes (spec) and `commonplace-plan` (sequencing) · **Repo:** `yepochs` · **Updated:**
2026-08-23

> ⭐ **ALL EIGHT QUESTIONS BELOW HAVE BEEN RULED ON.** See
> [`proposals/2026-08-23-rulings-on-open-questions.md`](proposals/2026-08-23-rulings-on-open-questions.md)
> (sha256 `3e38e3fa…`). Each section now records the ruling and what changed in this repo. **Nothing
> here is awaiting an answer.** What remains outstanding is a *specification* revision — §9 of the
> rulings lists ten required spec edits — and one `commonplace-plan` integration milestone.

Everything here was **decided-but-not-by-me** or **undecided**, and is now **answered**. None of it blocked the library: it is
complete against spec r2 §6–§24 with coverage for §28.1–§28.4, and it compiles, tests, type-checks
and formats clean.

⭐ **Read the status column first.** Several of these questions have a *current behaviour that works
and is deliberately pinned by a test*. That is different from a defect, and this document would
mislead badly if the two were flattened together.

| status | meaning |
|---|---|
| 🟡 **PINNED** | The code does something specific and reasonable today, **and a passing test asserts it**, so a decision changes code deliberately rather than by drift. Not broken. |
| 🔵 **UNDECIDED** | Genuinely open. No behaviour depends on it yet. |
| ⛔ **GATED** | Decided elsewhere; not this repo's to satisfy. |
| ✅ **ANSWERED** | Closed, recorded here so it is not re-asked. |
| ⚪ **CHOICE** | I chose; flagged because a reader might expect otherwise. |
| ⭐ **RULED** | Answered by jes on 2026-08-23. The row says what changed here. |

---

## 1. ⭐ RULED — Fixture 19 — should a re-authored crossing return correspondence spans?

**§17** says a re-authored delta adds spans *"wherever the rebase adapter can prove that newly
authored destination items correspond to source items."* **§28.2(19)** then makes non-identity
spans a **mandatory fixture**.

⇒ **The 0.1 adapters can prove nothing.** They re-author from an observable diff: they know the
destination now reads `"abXYcdefgh"`, not which destination item answers which source item.

**Current behaviour (pinned):** a re-authored crossing returns an **empty** correspondence and a
receipt. Pinned by `test/conformance_test.exs:233`, whose failure message says to update it when
this changes.

**The question — which did you mean?**
1. a requirement for a smarter adapter that tracks provenance while re-authoring;
2. satisfiable only for the **absorbed** case, where destination items already exist and can be
   aligned; or
3. aspirational, given §17's hedge.

⚠️ **Why it matters beyond the fixture:** §17 says an unmapped dependency simply re-authors again.
Combined with an empty correspondence, that **latches** — a chain of re-authored edits never
recovers strict translation until a fresh snapshot re-establishes one.

### ⭐ Ruling

**Zero or more proven spans; empty is valid in 0.1.** A re-authored crossing MUST return a receipt
and MUST return every correspondence it can prove — and that set MAY be empty. **The specification
must not require a non-identity span**; fixture 19 is replaced by four fixtures.

⇒ **The behaviour was conforming; the FIXTURE changed.** `test/conformance_test.exs` now carries
19a–19d: a receipt plus zero-or-more spans, an empty correspondence being valid, a later dependent
edit still crossing, and — for 19d — an assertion naming what must be added if any adapter ever
starts claiming provenance.

The latch is acknowledged as a consequence rather than a defect: recovering strict translation
through provenance-aware adapters is *"a desirable optimization, not a 0.1 correctness
requirement."*

---

## 2. ⭐ RULED — Tombstones narrow the strict path much further than §15 reads

Full write-up: [`design/0004`](design/0004-tombstones-narrow-the-strict-path.md).

Three clauses interact and the result is stated nowhere:

- **§10.5** — snapshots promise no mappings for source tombstones.
- **§15.8** — every delete-set interval MUST be translated, or strict translation fails.
- **The substrate** — `Encoding.encode_diff/2` includes the document's **entire** delete set;
  delete sets are not filtered by a state vector.

⇒ **Any edit authored on a document that has ever had a deletion carries pre-existing tombstone
coordinates the derivation does not map, so strict translation fails and the crossing re-authors.**

**Measured** against upstream-`yjs`-authored vectors: the two tombstone-free cases translate
strictly; all three with deletions fail on the **delete** field. **Control:** the same edit against a
document assembled from only the first update — identical except nothing deleted — translates fine.
So it is the tombstones, not the foreign bytes, the client ids, or the edit.

**Current behaviour (pinned):** per-case crossing modes asserted in
`test/yjs_conformance_test.exs:194`, with a failure message saying the interaction changed.

**Options, none chosen:**
1. **Map tombstones in the derivation.** §31 already lists *"tombstone-preserving snapshots and
   bridges"* as deferred — so this is an argument about priority, not a new idea.
2. **Let strict translation tolerate an uncovered delete range already satisfied at the
   destination.** §15.8 declines this today: *"does not **silently** discard."* ⚠️ Note the word — a
   *checked* discard against a supplied destination state is a different proposition.
3. **Have the caller trim the delete set** to the edit's own deletions. Cheapest, but makes the
   caller responsible for a wire-format detail that is easy to get wrong and silent when wrong.

### ⭐ Ruling — option 2, implemented inside the library

**Checked omission**, and explicitly **not** option 3: *"The caller MUST NOT be responsible for
knowing that Yelixer's `Encoding.encode_diff/2` includes the document's cumulative delete set."*
Tombstone-preserving snapshots stay deferred.

**Implemented.** Each clock of a delete interval is classified as translated, checked-historical
(omitted) or novel-and-uncovered (a failure), so a mixed interval splits. Omissions appear in the
preflight plan's `omitted` field, never silently in the encoder. `translate/4` has no endpoint
states and so stays conservative **by construction**; `cross/5` supplies them and keeps the strict
path.

⇒ **Upstream Yjs vectors 003–005 now cross as `:translated`**, where they previously re-authored
solely for repeating pre-existing tombstones.

⚠️ **A bug worth knowing about, found implementing this:** my first version of the ruling's
condition (c) checked the destination for a live item at the **same raw coordinate**. The snapshot
mints under the smallest source client id, so a destination routinely holds live items at
coordinates numerically equal to source tombstones — comparing them is raw numeric equality *across
epochs*, which invariants 1 and 9 forbid. Condition (c) in fact **follows** from (a) and (b) and
needs no lookup.

---

## 3. ⭐ RULED — determinism is over the exact `Doc` representation

**§15.10** requires byte-deterministic translated output. **§10.4** pins determinism to *"the same
decoded source state, including its Yjs item identities and supported struct representation."*

⚠️ **That clause is load-bearing and is stated only in §10.4.** Measured (see
[`design/0002`](design/0002-encode-determinism.md)): two callers holding the **same observable
document** hold **different `Doc` terms** when their updates arrived in a different order relative to
causal dependency — even when the edits commute. `yepochs` cannot detect this and does not try.

**Not a problem for translation**, which never builds a `Doc` by applying updates. **It is a problem
for `snapshot/2` and `rebase/4`**, which take caller-supplied `Doc`s — and §18 assigns path discovery
to the caller, so a caller may legitimately assemble histories in different arrival orders.

**Proposed clause:** state explicitly that byte-determinism is conditional on the caller's `Doc`
having a fixed struct representation, and that a differently-assembled `Doc` is a **different
input**, not a violated guarantee.

### ⭐ Ruling — and it TIGHTENS the contract rather than relaxing it

The normative caller contract is now stated on every Doc-taking API — `snapshot/2`, `rebase/4`, and
`cross/5` for both `source_before` and `destination`:

> Byte determinism is defined over the exact Yelixer `Doc` representation supplied by the caller,
> including item identities, struct boundaries, and arrival-dependent internal representation. **Two
> Docs with the same observable value but different internal representations are different inputs.**

⛔ The library **must not claim canonicalization** across different valid internal representations
of one observable value. Not a precondition of `translate/4`, which never constructs a Doc.

⇒ ⛔ **If §10.4's "including its struct representation" is ever simplified to pin the decoded
*value*, §10.4 becomes unsatisfiable on this substrate overnight.**

---

## 4. ⭐ RULED — criterion 14 leaves the library acceptance set

`commonplace-plan` owns this and has ruled the gated act is **`commonplace` taking a dependency on
`yepochs`, in either direction of arrival, even if no file ever moves.**

⇒ **Not satisfiable from this repo, by design.** `yepochs` depends on yelixer pinned at `bc35a0e9`
— the same ref commonplace pins — and on nothing else; it is unpublished and unwired, so the
dependency cannot arrive by accident.

### ⭐ Ruling

Criterion 14 **moves out of 0.1 acceptance** and becomes a `commonplace-plan` integration milestone
(*"`commonplace` takes a pinned dependency on `yepochs` and routes at least one existing crossing
path through it"*). It is replaced by a library-owned criterion:

> The package exposes the complete documented API and can be consumed by an external Mix project
> without a Commonplace dependency.

⇒ **That half is testable and now tested** (`test/invariants_test.exs`): no Commonplace package in
the dependency tree, no `Elixir.Commonplace*` module loaded, and every documented public function
exported.

■ Reading commonplace's tree and recreating its fixtures remains **explicitly not gated** and has
been done (§28.1). *"Mutating the Commonplace dependency graph does not."*

---

## 5. ⭐ RULED — specs name architectural LAYERS, not repository locations

Asked whether *"Remains in `commonplace-merkle-crdt`"* meant that repo or the `commonplace`
codebase. **Answer:** *"the specs could easily be confused about repo boundaries."*

⇒ **Taken as standing guidance:** the technical direction is authoritative; **repo attributions are
not**. Before designing to any *"X remains in repo R"* claim, `command grep` R's tree.

**Verified instance:** r2 assigns `CrossEpochMerge` / `Merger` / `SnapshotAncestry` to
`commonplace-merkle-crdt`, whose `lib/` contains **zero** references to them — all three are in
`~/commonplace`. (Control: that `lib/` holds two modules total, so the zero is real.)

### ⭐ Ruling

Repository-placement claims are **advisory and MUST NOT be treated as architectural requirements**.
Normative language should name layers instead: commit ancestry and common-ancestor discovery belong
**above** `yepochs`, in the Merkle-CRDT layer; crossing policy, bridge persistence, signatures and
commit construction belong to their stated layers; current modules **may remain** in the Commonplace
monorepo until a separate extraction plan moves them.

⇒ *"Before asserting that a module 'remains in repository R,' an implementation plan MUST verify
that repository's current tree."*

---

## 6. ✅ Naming — settled

Spec r2 uses both `Yepochs` and `YEpochs`; four of the ten `YEpochs` uses are normative, so it was a
genuine ambiguity rather than a typo cluster. **Ruled: "Yepochs is correct."** Implemented
throughout.

---

## 7. ⭐ RULED ACCEPTED — the choices I made

**All four accepted.** §7.3 additionally names my synthetic-name post-condition as *"the correct
guard"* and confirms *"silent loss of XML children is never acceptable."*

| choice | why |
|---|---|
| Built-in rebase adapters live in `rebase.ex`, not §29's `rebase/{text,map,array,xml}.ex` | §29 is a *suggested* layout and §24 permits the split to change. Four files would spread one dispatch decision across five modules. The behaviour §19.2 requires — `Yepochs.Rebase.Adapter` — **is** present. |
| No dedicated Y.XML adapter | Measured first: only `XMLText` and element **attributes** survive the snapshot replay; element **children** are dropped by it, so such documents can hold no bridge. Both surviving shapes are already carried by the plane dispatch. |
| `Derivation.to_map/1` emits `"spans"`; `Bridge.to_map/1` emits `"correspondence"` | §8.6 gives only a bridge example. A bare derivation's key is unspecified. |
| Decode-time limits are applied by `Update.decode/2` only | A caller handing `Preflight` an already-decoded `Update` bypasses them. Defensible — decode is the only way to obtain one from untrusted bytes — but written down at the test rather than left implicit. |

---

## 8. ⭐ RULED — the smaller items

- **§28.4 cross-language vectors are five cases.** They cover concurrent inserts, sequential inserts,
  and three delete shapes. Nothing exercises maps, arrays, or XML against upstream.
- **`inverse_derivation_map/1` in commonplace has no bijection guard** — two new ids naming one old
  id lose an entry to a map-key collision, silently. ⚠️ **Whether it can actually reach that state
  is unknown**: it requires the replay to emit more items than the source holds, which I have **not
  observed**. Recorded as a latent hazard, not a measured defect.
- **The experimental derivation map covers a fraction of the clocks** — eight one-character inserts
  replay as one eight-clock item, and the item-start map then covers **1 of 8**. ⇒ Measured evidence
  for §27.1's spans-over-item-start-maps, which the spec asserts without demonstrating. ⚠️ Its
  failure mode is a **visible refusal**, not a wrong answer.
- **Derivation maps are persisted** into snapshot commit metadata and are **content-addressed
  inputs** ⇒ changing how they are built **changes commit ids**. No fix here is drop-in.

### ⭐ Rulings

- **Cross-language vectors:** the five upstream text vectors establish **text/delete
  interoperability only** and *"MUST NOT be presented as evidence for maps, arrays, or XML."* One
  upstream-authored crossing vector per claimed type is required before 0.1 claims more.
  ✅ **Done:** cases 006–010 (three `Y.Map`, two `Y.Array`) generated against upstream `yjs`
  13.6.32 by `conformance/map_array_corpus.mjs`. ⚠️ **No XML vectors and no XML claim** — element
  children cannot survive the snapshot replay, so such documents can hold no bridge.
- **Inversion guard:** every inversion API MUST validate the partial bijection first; a map-key
  collision MUST return `:invalid_derivation` and **must not silently discard a correspondence**.
  Already true here; now asserted directly in `test/invariants_test.exs`.
- **Clock spans:** the measured one-of-eight coverage is *"sufficient evidence for the clock-span
  requirement."*
- ⭐ **Span-complete derivations are snapshot algorithm VERSION 3, not 2.** Version 2 stays the
  legacy item-start algorithm. ⇒ **This build was stamping v3 semantics as v2** — one durable
  version tag with two meanings. Fixed: `Algorithm.snapshot/0` returns v3, and `snapshot_v2/0` is
  *recognised but never produced*, so requesting it returns `:incompatible_algorithm`.

---

## Still outstanding after the rulings

1. **The specification revision itself.** §9 of the rulings lists **ten required spec edits**; this
   repo tracks them but does not own the spec.
2. **The `commonplace-plan` integration milestone** (ruling 5) — not this repo's to satisfy.

⇒ **Neither is actionable from this repo.** Generating cross-language vectors *was*, and is done:
Node and upstream `yjs` are available here, which I initially and wrongly assumed they were not.

## What I explicitly did *not* do

⛔ Invent answers to 1, 2 or 3 while they were open. Each had a current behaviour that worked, was
pinned by a test, and was cheap to change once decided.

⇒ **That turned out to matter more than expected: the rulings answered them per-item, in this
document's ordering, with its status distinctions intact — and two of the three reversed nothing
while the third moved real work into this library.** A guessed answer to any of them would have been
an undocumented decision by the time the real one arrived.
