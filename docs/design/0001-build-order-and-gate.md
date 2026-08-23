# 0001 — Build order, and where the extraction gate actually sits

**Status:** active · **Date:** 2026-08-23 · **Supersedes:** the gate wording in `README.md`

## The build order is a consequence of one measurement, not a preference

`Yelixer.Doc.t()` appears in exactly **two** API families across all 1315 lines of
[the spec](../proposals/2026-08-22-yepochs-spec.md): `snapshot/2` (§10.1) and `rebase/4` (§19.1).
Everything else in the normative API — derivation, bridge, lookup, inversion, composition,
extension, wire form — is integer interval arithmetic over `{client_id, clock}` pairs.

Verify it, don't trust it:

```
command grep -n 'Yelixer' docs/proposals/2026-08-22-yepochs-spec.md
```

That yields three tiers:

| Tier | Contents | Depends on | Substrate risk |
|---|---|---|---|
| **0** | `Span`, `Derivation`, `Bridge`, `Algorithm`, `Error`, `Limits`; validate/normalize/invert/compose/extend/lookup/to_map/from_map. §8, §9, §11–§14, §17, §22, §23, §28.3 | **nothing** | none |
| **1** | `Preflight`, `Translator`. §15, §16, §18, §27.2 | yelixer update codec | see §"encoding" below |
| **2** | `Snapshotter` v2, `Rebase`. §10, §19 | yelixer `Doc` + commonplace fixtures | highest |

Tier 0 depending on nothing — *not even yelixer* — is deliberate. It makes the gate below a
property of the code rather than of anyone's memory.

## ⛔ The gate — corrected wording, and it is narrower than it first looks

`commonplace-plan` owns ranking across this family. The gated state is **not** "files moving out of
`commonplace`". It is:

```
OPEN    building the yepochs library, on its own, on the yelixer substrate
GATED   `commonplace` TAKING A DEPENDENCY ON yepochs
        -- either direction of arrival: files moving out, OR a dep edge coming in
        -- and it stays gated EVEN IF NO FILE EVER MOVES
```

The reason the wording had to change: a greenfield `yepochs` that independently implements the same
semantics can become a *de facto* extraction **by convergence** — someone reasonably says
"commonplace should just use yepochs", and the extraction arrives as a consequence rather than as a
decision. The corrected wording makes that moment one nobody can reach by accident.

### ✅ What is NOT gated — recorded because over-escalation is its own failure

⭐ **Reading commonplace's code and reproducing its fixtures is NOT the gated moment.** Ruled
explicitly by plan on 2026-08-23:

> *"You reading commonplace's fixtures is a one-directional, test-time read that leaves
> commonplace's dependency graph untouched. Do it freely; don't escalate for it."*

The gate should stay **silent** through all three tiers and fire exactly once: when a change to
**commonplace** would make it consume `yepochs`. A gate that fires on correct behaviour trains
people to route around it, and a routed-around gate protects nothing while still reading as
installed.

### The structural enforcement

`mix.exs` deps are `[{:stream_data, only: :test}]`. `yepochs` is unpublished and unwired, so
commonplace cannot acquire a dependency on it by accident. **The gated moment has to arrive late
and visibly rather than early and implicitly.**

### Escalation triggers — publish to `commonplace-plan`, do not decide locally

1. Anything that would make **commonplace** consume `yepochs`.
2. **Linearization pressure.** DAG→log linearization is *deliberately unowned*. §26 assigns
   `CrossEpochMerge`, `Merger`, and `SnapshotAncestry` away from `yepochs`, and §4 lists "discovery
   of a common ancestor" and "selection of a merge strategy" as explicit non-scope; §18 assigns path
   *discovery* to the caller. If the design reaches for ancestor selection or path discovery, that
   closure has been broken — publish before writing it.

## Substrate finding: yelixer `encode_update/1` path-dependence

Measured by `commonplace-merkle-crdt` on 2026-08-23; reproducer at
`commonplace-merkle-crdt@ba5efba`, `test/encoding_path_dependence_test.exs` and
`conformance/yjs-v1/00{3,4}-concurrent-*-deletes/`.

- **It is path dependence on construction history, NOT nondeterminism on a fixed `Doc`.**
  `encode_update/1` on one fixed `Doc` term gave 1 distinct output over 200 calls. Two docs that
  integrated the same updates in different orders are *different Elixir terms* — same block count,
  different block *boundaries*.
- **It does not reach the delete set.** `encode_delete_set/1` was byte-identical in both orders;
  `DeleteSet.add_range/2` coalesces order-independently. So §15.6 and the §27.2 correction are not
  the exposed surface.

⭐ **§10.4 survives — but on a load-bearing clause.** §10.4 pins "the same decoded source state,
**including its Yjs item identities and supported struct representation**". Struct representation is
*exactly* what differs between two apply-orders, so such docs are not "the same decoded source
state" and §10.4 never promised they would agree.

> ⚠️ **If anyone ever "simplifies" §10.4 to pin the decoded *value* instead of the struct
> representation, §10.4 becomes unsatisfiable on this substrate overnight.** This clause is not
> boilerplate. A Tier 2 implementation must carry this warning at the site.

⛔ **Reproducing it requires concurrent overlapping *deletes*. Insert-only histories will NOT
reproduce it** — a wrong conclusion was already published once from exactly that mistake. Build an
independent probe at Tier 1 rather than inheriting this result.

## Open spec questions — for jes, not decidable locally

1. **§26's referent may be misaddressed.** §26 rules `CrossEpochMerge` / `Merger` /
   `SnapshotAncestry` as *"Remains in `commonplace-merkle-crdt`"*. But those modules live in
   `~/commonplace` (`apps/commonplace/lib/commonplace/store/`), owned by the `commonplace` agent;
   `commonplace-merkle-crdt` is a **reducer plugin** holding no commit graph and no store, and it
   currently *refuses* snapshot-kind commits with a named error because derivation maps are not
   available to a plugin. "Stays with the caller" is a very different design when the caller does not
   exist in the shape §26 assumes. **Does not block Tier 0.**
2. **Extraction surface is ~1020 lines, not 124.** Measured on commonplace main:
   `namespace.ex` 424 · `snapshotter.ex` 232 · `late_edit_preflight.ex` 169 ·
   `late_edit_translator.ex` 124 · `document/rebase.ex` 71 — plus *pure orchestration only* out of
   `translator.ex` (346). `cross_epoch_merge.ex` (420) is **not** on the map. plan has retired its
   "is 124 lines a package or a module" question on this denominator.

## Naming: `Yepochs`, not `YEpochs`

The spec uses both. `YEpochs` appears 10 times, **all in prose and tables**; every struct
definition (§8.1–8.4, §10.1, §15.1) and the entire §24 "Initial public API" block uses `Yepochs`.
⇒ `Yepochs` is normative; `YEpochs` is a typo. Module namespace is `Yepochs.*`, app is `:yepochs`.
