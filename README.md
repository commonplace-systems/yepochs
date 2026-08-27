# yepochs

Sibling to [yelixer](https://github.com/commonplace-systems/yelixer) — commonplace's epoch handling,
extracted into its own package.

## Status

**Last full `mix check` ran against the tree at `00a1102` (2026-08-27, under `bin/box-sample.sh`):
spec r3 §6–§24 implemented, epoch-token minting shipped, 629 runner tests + 12 properties,
0 failures, Dialyzer `Total errors: 0`; consumed by `commonplace-merkle-crdt` for compaction
openers.**

⛔ **A RUN IS EVIDENCE ABOUT THE SHA IT RAN AGAINST AND DOES NOT TRAVEL FORWARD.** This line
previously named `55bd714` — **thirty commits stale, and `test/` had changed between that sha and
the run that produced these numbers.** The verdict was right and the referent was wrong, which is
the shape that does not read as an error.

✅ **What makes the numbers still load-bearing is not the date but a CHECKABLE INVARIANT: no commit
since `00a1102` has touched `lib/` or `test/`.** Verify in one command, and trust the command
rather than this sentence:
```sh
git diff --name-only 00a1102..HEAD -- lib/ test/     # empty ⇒ the verdict still covers the tree
```
⚠️ **Everything committed since is `bin/` and `docs/`.** Those cannot change the suite's verdict —
**which is a different claim from "they were gated", and this file says which one it means.**

⭐ **Every gate in this repo, and how far it has actually been demonstrated, is in
[`docs/THRESHOLD-AUDIT.md`](docs/THRESHOLD-AUDIT.md)** — including the rows that are **latent**,
the ones whose **wiring** is unexercised, one arm that is **downstream of the action and cannot be
stubbed**, and the two occasions the slot interlock was **disarmed by the teardown of the test that
exercises it**.
⛔ **It is linked from here because a filed artifact fires only if something reads it.** It had no
inbound link for its first two hours: filed, and firing for nobody.

⚠️ **This line is rewritten at every landing and is never appended below.** A count without the sha
it was measured at is a claim about a moment nobody can identify.

■ **Host state is deliberately NOT recorded here**, and the reason is the rule rather than an
omission: this line reports **counts and exit codes**, which are not timing-sensitive — a failing
test fails at load 1 or load 44. ⇒ Record the box state beside a **duration** or a **flaky red**,
where it is unrecoverable afterwards and load is a candidate cause. *(`commonplace-plan`'s addition:
a count without its host state is a number without its population, in a new dimension.)*

⛔ **"628 RUNNER tests" names its POPULATION, and that is not decoration.** The same tree has **367
source-visible `test "` lines** — both true at the same sha. A `for` comprehension in
`test/totality_test.exs` generates **260 runner tests from one source line**, so the two counts
diverge by +261 with no defect anywhere. ⚠️ A count with a sha but no population is still ambiguous,
and I read a survey's correct source-line figure as a stale runner figure for exactly that reason.
⇒ ⭐ **A genuinely stale count is a number this tree once produced. 367 never was — that is the
discriminator, and "it disagrees with mine" is not one.**

⛔ **It names the sha the measurement was TAKEN at, not this commit's own.** A commit cannot name
itself — writing the name changes the hash, and amending to fix it changes it again. ⇒ *"the sha it
was measured at"* is the only form that is stable, and it is exact: docs-only landings do not move
the count, so the measurement sha legitimately trails the head.

The surface, against spec r3:

| area | spec | state |
|---|---|---|
| Span · Derivation · Bridge · Basis · Delta · Receipt | §8, §9 | ✅ |
| bridge lookup, inversion, composition, evolution | §11–§14, §17 | ✅ |
| deterministic snapshotting, algorithm v3 | §10 | ✅ |
| epoch-token minting, length-framed and domain-separated | `docs/design/0010` | ✅ `Yepochs.EpochToken.mint/3` |
| strict preflight and translation, both directions | §15.3–§16 | ✅ |
| bilateral crossing — translated / re-authored / absorbed | §15.1, §15.2 | ✅ |
| strict path translation | §18 | ✅ |
| positional re-authoring | §19 | ✅ Y.Text, Y.Map, Y.Array, the reachable Y.XML surface, and a `Rebase.Adapter` behaviour for application schemas |
| error model and resource limits | §22, §23 | ✅ |
| explicit algorithm-version selection | §21 | ✅ refuses substitution in either direction |

**Measured at `9f5e5f2`: 12 properties, 628 tests, 0 failures** — including §28.4 conformance vectors authored by **upstream
`yjs` 13.6.32**, not by this stack. Ten vectors: five text/delete, and five
`Y.Map`/`Y.Array` generated for ruling 8.1. ⚠️ **No XML vectors and no XML claim** — element children
cannot survive the snapshot replay, so such documents can hold no bridge. `mix check` runs formatting, `--warnings-as-errors`, the suite, and Dialyzer.

⚠️ **Dialyzer's `flags:` REPLACES its default warning set — it does not extend it.** This project
enables exactly **`error_handling`, `extra_return`, `missing_return`, `unmatched_returns`**, so
`invalid_contract`, `no_return` and the rest of the default set are **NOT checked**. ⛔ Calling that
"strict flags", as this README did until 2026-08-27, overstates it: the set is *narrower* than the
default, chosen deliberately, not wider.

⭐ **Measured, because a green stage proves nothing about what it can catch:** a public function
declaring `{:error, _}` while returning `{:ok, binary()}` passes cleanly under those four flags, and
the same defect under `:underspecs`/`:overspecs` gives **`Total errors: 35, rc 2`**. ⇒ The dialyzer
stage **can** fail — it is not decoration — but it is blind to spec/contract mismatches by
construction. Those two extra flags are not enabled because they report **34 findings on clean
code**, which is a deliberate trade and now a recorded one. Every load-bearing check is
**mutation-tested** — disabled one at a time to confirm the suite reddens. That practice found
ornamental gates in *every* module it was applied to, and three genuine defects it would otherwise
have missed. See [`docs/design/`](docs/design/).

⛔ **Two known gaps, both recorded as failing-by-design tests rather than omitted:** §28.2 fixture 19
(a re-authored crossing returning non-identity correspondence spans — 0.1's adapters can prove none),
and §30 criterion 14 (commonplace consuming the package), which is gated and not this repo's to
satisfy.

## What would move here — measured 2026-08-23, not assumed

Both modules exist on `commonplace` main today:

| File | Lines |
|---|---|
| `apps/commonplace/lib/commonplace/store/translator.ex` | 346 |
| `apps/commonplace/lib/commonplace/store/cross_epoch_merge.ex` | 420 |

⚠️ **Both currently depend on `Commonplace.Store`**, which is why commonplace-plan recorded them as
*"need `Commonplace.Store` and stay"* — the dependency has to be broken before either can leave.
Plan's open question, in its words, is **"whether 124 lines is a package or a module."**

## ⚠️ There are TWO spec revisions and they are indistinguishable by header

Both say `Version: 0.1-draft`, `Date: 2026-08-22`. **Tell them apart by sha256.**

| revision | path | sha256 |
|---|---|---|
| r1 | `docs/proposals/2026-08-22-yepochs-spec.md` | `c24ce9dd…` |
| **r2 — CURRENT** | `docs/proposals/2026-08-23-yepochs-spec-r2.md` | `8765bb15…` |

r2 makes Bridges **bilateral edit transducers**: one-directional translation became *crossing*, and
missing correspondence now **selects re-authoring instead of failing**. See
[`docs/design/0003-r2-migration.md`](docs/design/0003-r2-migration.md). r1 is kept because it is what
Tier 0 was first built against.

## ⛔ The gate — see `docs/design/0001-build-order-and-gate.md` for the binding wording

⚠️ **The section below is the ORIGINAL wording and it is superseded.** `commonplace-plan` corrected
it on 2026-08-23: the gated act is **`commonplace` taking a dependency on `yepochs`** — in either
direction of arrival, and it stays gated **even if no file ever moves**. Building the library is
open; ⭐ **reading commonplace's code and reproducing its fixtures is explicitly NOT gated.**

⇒ Read [`docs/design/0001-build-order-and-gate.md`](docs/design/0001-build-order-and-gate.md)
before acting on anything in this section.

## The sequencing constraint, recorded so it is not rediscovered late

commonplace-plan's queue carries two findings that bound when this extraction can happen:

1. **A yepochs consuming published yelixer REPEATS THE WHOLE GATE STRUCTURE** — it is *not* cheaper
   for having done the yelixer extraction once. The gate work does not amortize.
2. **Not before the arc lands: a mid-arc commit to yelixer invalidates a closed gate.**

⇒ **This is a real sequencing gate, not a caution.** Whether it is time to start is
**commonplace-plan's call** — it owns ranking across the commonplace family via
`commonplace-plan/docs/plans/QUEUE.md`. This repo existing does not re-rank it.

### ✅ SUPERSEDED 2026-08-23 04:28Z — jes supplied a spec and staffed it

jes: *"I'll try to get you a yepochs spec so we can have an opus there too."* He then sent one.
⛔ **TWO REVISIONS EXIST AND THEIR HEADERS DO NOT DISTINGUISH THEM** — both say
`Version: 0.1-draft`, both say `Date: 2026-08-22`. **Tell them apart by sha256, never by the header.**

| received | file | sha256 | lines |
|---|---|---|---|
| 04:28Z | `docs/proposals/2026-08-22-yepochs-spec.md` | `c24ce9dd…` | 1315 |
| **04:51Z — CURRENT** | `docs/proposals/2026-08-23-yepochs-spec-r2.md` | `8765bb15…` | **1718** |

⭐ **The r2 change that matters most: §15 went from *"Strict update translation"* to *"Crossing
edits"*, and §1 now reads "moving Yjs edits **in either direction**".** New §27.4 is *"Make Bridges
bilateral edit transducers"*, plus new §8.4 (bridge delta and receipt), §15.1–15.10, and §6.7–6.10.
⇒ **One-directional translation became bilateral crossing.** Anything built against r1's Bridge
semantics should be re-read against r2 before extending.

⇒ The r1 spec is filed byte-identical at
[`docs/proposals/2026-08-22-yepochs-spec.md`](docs/proposals/2026-08-22-yepochs-spec.md)
(sha256 `c24ce9ddb9919fdf6846737f0ee2425320bc71d89a932211e09029958d055e34`) and an Opus worker runs
here.

⚠️ **The ruling below is NOT deleted, because its REASONING still binds** — what changed is the
premise, not the argument. plan ruled against staffing *an empty repo with no spec*; the repo is no
longer empty and the direction is no longer absent. ⛔ **The §5 sequencing gate is untouched and
still applies to the EXTRACTION itself** (see above): a yepochs consuming published yelixer repeats
the whole gate structure, and not mid-arc.

⇒ **Spec work and library design can proceed. Landing an extraction that displaces `commonplace`'s
`translator.ex` / `cross_epoch_merge.ex` is still plan's to sequence.**

### ⛔ RULED 2026-08-23 04:0xZ by commonplace-plan: NO AGENT, NO START (premise now superseded)

Asked directly whether to staff this repo, plan ruled no, and gave the reason in a form worth
keeping at the top of the file someone opens when they are about to start:

> **An empty repo is a NAME, and naming a thing is the cheapest possible act — it should
> therefore carry the least ranking weight, not the most.**

⭐ A new empty repo carries an implicit *"start me"* it has not earned by comparison with anything
already ranked. That is recency-as-priority in its purest form: **an artifact whose mere existence
argues for work.** ⇒ **Repo existence is not extraction.** The sequencing gate above stands
unchanged.

jes, same day, independently: he is writing a spec first, and an agent goes in after that.

## Consumers waiting on it

- `commonplace-merkle-crdt` — jes named yepochs as something that repo needs to know about.
- The §5 vertical slice, which plan records as **gated on this extraction** rather than startable
  today.

## Wake conditions

⛔ **These live here, not only in another agent's file.** Wake conditions recorded only by whoever
is watching are lost when that watcher's context is. `commonplace-merkle-crdt` moved its own into
its README for the same reason; this is the counterpart.

**Wake this repo when:**

1. ⭐ **Anyone touches epoch minting rules** — the boundary between "ordinary edits" and
   "deterministic re-authoring" is load-bearing for fork push-back, and the plausible tightening
   *"every fork mints an epoch"* is the one that breaks it silently. Guarded by
   `test/epoch_boundary_test.exs`; see `docs/design/0008`.
2. **`commonplace-merkle-crdt`'s epoch awareness advances** — it carries the token and never
   computes it, so minting questions land here and in `commonplace`.
3. ⭐ **A second consumer needs the minting function.** `Yepochs.EpochToken.mint/3` shipped at
   `cf17c4c`; its conformance vectors are in `docs/design/0010` and a re-implementation fails them
   immediately. ⛔ **Consumers MUST re-export, never reimplement** — two implementations are two
   tokens.
4. ⛔ **The monolith is proposed as a consumer of `commonplace-merkle-crdt`** — that revives the
   `commonplace` → `yepochs` gate transitively, and it is a new decision rather than a consequence
   of the 2026-08-24 grant. See the standing cautions below.
5. ⭐ **This repo's `yelixer` pin changes** (`mix.exs` ref / `mix.lock`).
   `commonplace-merkle-crdt` keeps a detached clone at exactly that ref
   (`~/yelixer-pin-bc35a0e9-merkle`) and its drift test checks that clone
   **against this repo's lock**. ⇒ Moving the pin breaks their test by design —
   which is the point — but they should hear it from here first rather than
   from a red suite. **They pin this repo by ORIGIN SHA** (`git:` + `ref:`, no longer a path
   worktree, as of 2026-08-25) **— so tell them before any behavioural change,
   and note a moved pin now requires a push, not just a local commit.**

   ⚠️ Six further repos (`doc`, `cell`, `next`, `markdown`, `dir`, `doc-sync`)
   declare `{:yepochs, git: …, override: true}`. **Measured: all six call
   `Yepochs.*` in ZERO files; `merkle-crdt` calls it in 4.** ⇒ Those are
   diamond-resolution **overrides, not API consumption** — the grant's "one
   consumer" boundary holds in substance. ⛔ Do not read a `mix.exs` entry as
   usage without checking for call sites.
6. **A snapshot algorithm version is proposed** — §21 requires a new version for any change that can
   alter output bytes or mapping semantics, and deterministic minting depends on the version riding
   along with the token (`docs/design/0009`).
7. **Anyone proposes deriving epoch identity from content** — measured impossible: a single-author
   re-authoring emits byte-identical output, so no pure function of the bytes distinguishes the
   namespaces (`docs/design/0008`).
8. ⭐ **The box clears `available > 2500 MB` across several samples** — then adopt the two-run
   landing design: plain `mix test` is the **verdict** (real timeouts, real concurrency), a
   `--trace` run supplies arm names and must also pass, and **a plain-fails/traced-passes
   disagreement is a timing-or-concurrency class, NOT a flake to retry away**. ⛔ Deferred only
   because it doubles a 629-test + 12-property suite under a memory hold — not because it was
   judged unnecessary. See `docs/design/0011`.

## Mutation testing

`bin/mutate.sh <file> <old> <new> [test target]` applies a substitution, runs the tests, and always
restores the file — including on a signal.

⛔ **It refuses a substitution that changed no bytes (exit 3).** That is the check it exists for: a
malformed mutation reads *exactly* like an ornamental gate — both are "I changed it and nothing
happened." This was hit three times by hand in one session before being filed, once because
`mix format` had wrapped a line so a single-line pattern never matched.

Exit codes: **0** caught (gate works) · **1** survived (gate suspect) · **2** usage or a dirty target
file · **3** mutation changed nothing.

⚠️ **A weakening mutation always survives and proves nothing** — invert the assertion or break the
mechanism instead.

## Briefing a Sol implementer

`bin/` and `docs/design/0010` are the pattern: **write the conformance vectors before the
implementation**, so a reimplementation fails immediately rather than plausibly, and so there is
something independent to check the result against afterwards. Verify the returned vectors against
the reference **in both directions** — a test that hard-codes hashes its own implementation produced
is self-consistent and worthless.

⭐ **Give the brief an explicit way to say "this arm cannot be written honestly."** A round that ends
**red for a named reason** is worth more than one that ends green: the alternative is an invented
sentinel manufacturing a pass. Borrowed from `commonplace-value`, whose round hit exactly this and
whose implementer correctly left the gate red rather than fabricate one — the premise then turned
out to be untestable on that OTP version, which is a **finding**, not a failure.

⚠️ Name what the sandbox masks in the brief, so a negative result can be read rather than believed.

⛔ **And here is the list, because an instruction to "name what it masks" that does not name them
cannot be followed from this file.** Measured 2026-08-27; the fence hides `~/.ssh`, `~/.config/gh`,
`~/.claude/channels`, and tmux/system sockets.
⇒ ⭐ **ANYTHING MEASURED INSIDE THE FENCE INHERITS THE FENCE AS A FACT.** An implementer reporting
"no credentials found", "the channel is empty", or "gh is unavailable" is reporting the sandbox, not
the world — and that reads identically to a finding about the repo.

### The runner, and what it does not do

⛔ **`sol-egress-run.sh` is the runner *WITH* egress. The filename reads like the opposite.** It
lives in **another agent's tree** (`~/boss-clod/`), so invoking it is a **runtime read of someone
else's working copy**: it can be mid-edit when you run it, exactly as a shared health script can.
⇒ **Verify by sha when it matters, and treat a syntax error from it as an editing event rather than
a defect in your own round.**

⚠️ `SOL_MAX_PARALLEL` defaults to **2**.

⛔⛔ **SOL CANNOT COMMIT.** The dispatcher commits on its behalf — so a round that "finished" leaves
the work in the tree and nowhere else. **Check the tree, not the transcript.**

⚠️ This dispatch is **hand-typed, not scripted, in this repo.** That is the third position in the
artifact trade: a shared copy is exposed to *tearing*, a private copy to *drift*, and **no artifact
at all to non-repeatability — no fixed referent to be wrong the same way twice.** Recorded as a known
gap rather than presented as lightness.

⛔ **Counting rounds in flight: count distinct PGIDs of processes whose `comm` is exactly `codex`.**

```bash
pgrep -u "$USER" -x codex | xargs -r ps -o pgid= -p | tr -d ' ' | sort -u | grep -c '[0-9]'
```

⛔⛔ **THE HAZARD IS NOT THE `-f` FLAG. IT IS MATCHING ON ANY STRING YOU ALSO TYPED.** Naming `-f`
was too narrow, and the bracket idiom `grep '[c]odex'` is **a partial mitigation that reads like a
complete one**: it stops the grep matching itself, and stops nothing else. Measured across the fleet
2026-08-27 — a bracketed args match reported **6 running suites where 2 were real**, and one of the
six was *the pre-flight command running the count*. A second door bracketed one token and still got
three self-hits, because the same string appeared elsewhere on its own command line.

⭐ **Enumerate by executable NAME, then read a kernel fact — do not filter a text match.** `pgrep -x`
matches `comm`, and prose cannot be an executable; `/proc/PID/cmdline` is then read only for
processes already known to be the right kind. A shell discussing the pattern, an editor with the file
open, and the measuring command itself are **structurally excluded rather than filtered out**. Always
report the unfiltered `pgrep -x` count beside it as the control.

⚠️ Args-matching also inflates by **~4 processes per round** (bwrap parents, wrappers), so a
concurrency figure recorded beside a failure lands on an axis several times too large — and the
multiplier is **not constant**, so it cannot be divided out afterwards. ⚠️ I used the `-f` form once this session and it returned the right answer only because the
true count was **zero**, which is robust to over-counting. A nonzero would have been wrong.

## Standing cautions for whoever reads this next

⛔ **Do not tidy `test/epoch_boundary_test.exs` into "every fork mints an epoch".** A fork that
branches over one Yjs history **keeps** its epoch; one that replays into fresh identities mints a
new one. Colliding namespaces cause **order-dependent silent loss** — Yjs deduplicates by
`{client, clock}`, so an edit is discarded with no error and the loser is chosen by arrival order.

⚠️ **Spec revisions are told apart by hash, not by header.** r1 `c24ce9dd…`, r2 `8765bb15…`
(byte-identical as filed by jes), **r3 `3f43be13…` is current** and carries `Version: 0.1-draft-r3`.
Amendment record: `docs/design/0007`.

⚠️ **Dependency status, as of 2026-08-24.** jes granted **`commonplace-merkle-crdt` → `yepochs`**
("i do want merkle-crdt to depend on yepochs"). `commonplace-doc` reaches this library **through
merkle-crdt's re-export**, keeping one content door.

⛔ **The grant covers that ONE edge and does not travel.** `commonplace-plan`'s crux — *is
merkle-crdt ever intended to be consumed by the monolith?* — **was not answered**, so if the monolith
is ever proposed as a consumer of merkle-crdt, **the `commonplace` → `yepochs` gate is live again and
that is a new decision.** ⇒ Do not let it arrive transitively on the strength of the merkle grant.

⭐ Measured true today, which is why the grant was safe: the monolith references merkle-crdt in
**zero** files, with zero `mix.exs` mentions; merkle-crdt's consumers are `commonplace-doc` and
`commonplace-dir`, both path-deps.

⛔ **And whoever consumes it MUST re-export, never reimplement.** Two implementations of the minting
function are two tokens, and two implementations of the span walk are two derivations — the failure
appearing as unresolvable references long after the artifact is durable. The conformance vectors in
`docs/design/0010` are what make that enforceable rather than a promise.
