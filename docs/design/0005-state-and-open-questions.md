# 0005 — Where this repo stands, and what is not decided

**Status:** current · **Date:** 2026-08-23 · **Read this first if you are picking the work up.**

## The one-paragraph version

`yepochs` implements spec **r3** (`docs/proposals/2026-08-23-yepochs-spec-r3.md`, sha256
`3f43be13…`), the satisfiability amendment recorded in `0007`; r2 is retained byte-identical at
sha256 `8765bb15…`. ⚠️ **r1 and r2 are indistinguishable by header; tell them apart by hash** — r3
carries `Version: 0.1-draft-r3`. The
library is complete against §6–§24 and has coverage for §28.1–§28.4. It depends on **yelixer pinned
at `bc35a0e9`** — the same ref `commonplace` pins — and on nothing else at runtime.

## ⛔ The gate, which has not moved

```
OPEN    building this library on the yelixer substrate
GATED   `commonplace` TAKING A DEPENDENCY ON yepochs
        -- either direction of arrival, and gated EVEN IF NO FILE EVER MOVES
```

`commonplace-plan` owns this. **Reading commonplace's tree and recreating its fixtures is explicitly
NOT gated** and has been done. §30 criterion 14 ("the Commonplace monorepo consumes the package") is
therefore **not satisfiable from this repo**, by design.

⚠️ **Standing caveat from jes:** *"the specs could easily be confused about repo boundaries."* The
technical direction is authoritative; the repo attributions are **not**. Before designing to any
"X remains in repo R" claim, `command grep` R's tree. Verified instance: r2 still assigns
`CrossEpochMerge`/`Merger`/`SnapshotAncestry` to `commonplace-merkle-crdt`, whose `lib/` contains
**zero** references to them.

## Two questions with jes — do not close them by inventing an answer

1. **§28.2 fixture 19** — a re-authored crossing returning *non-identity* correspondence spans. §17
   hedges (*"wherever the adapter can prove"*), and 0.1's adapters prove none: they re-author from
   an observable diff and cannot say which destination item answers which source item. The current
   empty-span behaviour is **pinned in a passing test** so an answer changes code deliberately.
2. **The tombstone interaction** — see [`0004`](0004-tombstones-narrow-the-strict-path.md). §10.5
   declines to map tombstones, §15.8 requires every delete interval be translated, and
   `encode_diff/2` carries the *whole* delete set ⇒ **the strict path is available mainly for
   documents that have never had a deletion.** Three options recorded, none chosen. Per-case
   crossing modes are pinned in tests.

## What was measured, and where it is written down

| finding | where |
|---|---|
| build order; why Tier 0 has no dependencies | [`0001`](0001-build-order-and-gate.md) |
| yelixer encode determinism — two distinct mechanisms | [`0002`](0002-encode-determinism.md) |
| which XML shapes can hold a bridge at all | [`0002`](0002-encode-determinism.md) |
| r1→r2 migration; `target`→`right` is a **swap**, not a rename | [`0003`](0003-r2-migration.md) |
| §22 / §29 audit; §28 fixture status | [`0003`](0003-r2-migration.md) |
| tombstones narrow the strict path | [`0004`](0004-tombstones-narrow-the-strict-path.md) |

## ⭐ How to work on this, learned the hard way

**A green suite is not evidence a check works.** Mutation testing — disable one check, re-run,
restore — found ornamental gates in **every module it was applied to**, and three genuine defects
no test noticed. The recurring cause is never a wrong assertion; it is *data that cannot exercise
the check*: a composition test clipping exactly at a span start so the offset was always zero, an
"is sorted" assertion over a single element, `receipts >= 0` on a bridge that always had none.

⛔ **The dangerous defects here all produce a plausible answer rather than an error** — an empty
snapshot, an absorbed no-op for a real edit, a delete range covering clocks nothing deleted. Tests
that compare *shape* survive all of them; tests that compare **identity or content at the endpoints**
do not. When a test passes on the first run, ask what data would make it fail.

**Other traps this repo has actually hit**, each now recorded at its site: `doc.types` records what
the registry was *told*, not what the document *holds*; a guard whose reference value is computed
by the same rule as the thing it guards cannot detect a fault in that rule (twice, in one function);
`grep` for "where is X built" finds only literal constructions and is blind to indirection; and
`:erlang.system_info(:atom_count)` is a global counter that races every async test.

## Verifying the state yourself

```
mix deps.get && mix test          # count moves; read it from the run, not from here
mix format --check-formatted      # clean
mix compile --warnings-as-errors  # clean
```

Probes needing the substrate live in `probes/` with their own README — run them from a throwaway
project, **not inside `~/yelixer`**.

## Coverage — 97.2%, and what the remainder is

`mix test --cover` is a **third partition**, distinct from both unit tests and mutation testing: it
does not ask whether a check works, only whether a line ever ran. It found **41 unexercised lines**
at 93.3%, most of them error and fallback branches — *the code that only runs once something has
already gone wrong, and therefore the least exercised and most likely to be wrong when it finally
is.* Among them a genuine §15.7 gap: an **ID-valued parent with no mapping** had never been tested,
so the distinction §15.7 draws between that and a missing anchor was unverified.

⚠️ **The residual ~3% is not a to-do list.** It is, deliberately:

- **function heads carrying default arguments** (`def snapshot(doc, opts \\ [])`) — cover attributes
  the head separately from the clause; there is no branch there to exercise;
- **`Snapshotter`'s `:lossy_nested_subtypes` arm** — `Yelixer.Doc.nested_subtype_names/1` returns
  `[]` for every shape reachable through the public type API, so the branch cannot be entered from
  outside. It stays because the substrate can start returning names without warning;
- **`Translator.rewrite_parent/2`'s catch-all** — yelixer emits only `{:named,_}`, `{:id,_}` and
  `{:infer,_}`. Forcing the branch with a hand-built `parent: nil` makes yelixer's *encoder* raise,
  which proves it defensive rather than reachable. ⇒ **A test asserts the guarantee instead of the
  branch:** across the upstream corpus and locally-authored documents, every decoded parent is one
  of the three. If yelixer adds a fourth, that test fails and the catch-all stops being defensive.

⭐ **Chasing the last few percent by contorting inputs would have converted honest defensive code
into tests that assert the contortion.** Where a branch is unreachable, the useful artifact is a
test of *why* it is unreachable — which fails if that stops being true.

## ⛔ A gate that could not fail, in the commit workflow itself

I committed a change with **four failing tests**, having run:

```sh
mix test 2>&1 | tail -3 && git commit …
```

⇒ **A pipeline's exit status is the LAST command's.** `tail` always succeeds, so `&&` always
proceeded — the `mix test` verdict never reached the gate. The failure count was printed, right
there on screen, and the chain ran anyway.

**Use one of these instead:**

```sh
mix test && git commit …                       # no pipe: mix test's status IS the gate
if mix test > /tmp/t.log 2>&1; then … else … fi # capture, branch on the real status
set -o pipefail                                 # if a pipe is unavoidable
```

⭐ This is the same defect as every ornamental check found in the test suite — *a check whose result
cannot change what happens next* — arriving in the tooling rather than in the code. It is worth
recording precisely because I had spent the day finding that shape elsewhere and still shipped it in
my own workflow.
