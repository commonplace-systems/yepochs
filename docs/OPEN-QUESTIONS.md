# Open questions

**For:** jes (spec) and `commonplace-plan` (sequencing) · **Repo:** `yepochs` · **Updated:**
2026-08-23

Everything here is **decided-but-not-by-me** or **undecided**. None of it blocks the library: it is
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

---

## 1. 🟡 Fixture 19 — should a re-authored crossing return correspondence spans?

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

⛔ **I have deliberately not invented a strategy to close this.**

---

## 2. 🟡 Tombstones narrow the strict path much further than §15 reads

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

⇒ **Practical summary:** the strict, identity-preserving path is available mainly for documents that
have never had a deletion. For a system whose premise is preserving Yjs authorship across epochs,
that is narrower than §15 suggests.

---

## 3. 🔵 §15.10 has no caller-side precondition, and needs one

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

⇒ ⛔ **If §10.4's "including its struct representation" is ever simplified to pin the decoded
*value*, §10.4 becomes unsatisfiable on this substrate overnight.**

---

## 4. ⛔ §30 criterion 14 — commonplace consuming the package

`commonplace-plan` owns this and has ruled the gated act is **`commonplace` taking a dependency on
`yepochs`, in either direction of arrival, even if no file ever moves.**

⇒ **Not satisfiable from this repo, by design.** `yepochs` depends on yelixer pinned at `bc35a0e9`
— the same ref commonplace pins — and on nothing else; it is unpublished and unwired, so the
dependency cannot arrive by accident.

■ Reading commonplace's tree and recreating its fixtures is **explicitly not gated** and has been
done (§28.1).

---

## 5. ✅ §26's referent — answered as a class caveat

Asked whether *"Remains in `commonplace-merkle-crdt`"* meant that repo or the `commonplace`
codebase. **Answer:** *"the specs could easily be confused about repo boundaries."*

⇒ **Taken as standing guidance:** the technical direction is authoritative; **repo attributions are
not**. Before designing to any *"X remains in repo R"* claim, `command grep` R's tree.

**Verified instance:** r2 assigns `CrossEpochMerge` / `Merger` / `SnapshotAncestry` to
`commonplace-merkle-crdt`, whose `lib/` contains **zero** references to them — all three are in
`~/commonplace`. (Control: that `lib/` holds two modules total, so the zero is real.)

---

## 6. ✅ Naming — settled

Spec r2 uses both `Yepochs` and `YEpochs`; four of the ten `YEpochs` uses are normative, so it was a
genuine ambiguity rather than a typo cluster. **Ruled: "Yepochs is correct."** Implemented
throughout.

---

## 7. ⚪ Choices I made that a reader might expect to have gone the other way

| choice | why |
|---|---|
| Built-in rebase adapters live in `rebase.ex`, not §29's `rebase/{text,map,array,xml}.ex` | §29 is a *suggested* layout and §24 permits the split to change. Four files would spread one dispatch decision across five modules. The behaviour §19.2 requires — `Yepochs.Rebase.Adapter` — **is** present. |
| No dedicated Y.XML adapter | Measured first: only `XMLText` and element **attributes** survive the snapshot replay; element **children** are dropped by it, so such documents can hold no bridge. Both surviving shapes are already carried by the plane dispatch. |
| `Derivation.to_map/1` emits `"spans"`; `Bridge.to_map/1` emits `"correspondence"` | §8.6 gives only a bridge example. A bare derivation's key is unspecified. |
| Decode-time limits are applied by `Update.decode/2` only | A caller handing `Preflight` an already-decoded `Update` bypasses them. Defensible — decode is the only way to obtain one from untrusted bytes — but written down at the test rather than left implicit. |

---

## 8. 🔵 Smaller things nobody has ruled on

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

---

## What I explicitly did *not* do

⛔ Invent answers to 1, 2 or 3. Each has a current behaviour that works, is pinned by a test, and is
cheap to change once decided. **Guessing would have converted an open question into an undocumented
decision** — which is the failure mode this document exists to prevent.
