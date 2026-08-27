# Threshold and guard audit

**Date:** 2026-08-27 · **Rule:** a labelled gap beats a manufactured green.

Every guard in this repo, and *how far* it has actually been demonstrated. The distinction that
matters is **predicate demonstrated** (the logic was exercised) versus **wiring demonstrated** (the
path a real caller travels was exercised). They are not the same claim and this file will not
merge them.

## ✅ Demonstrated red AND green, through the shipped path

| guard | red arm seen | notes |
|---|---|---|
| `bin/mutate.sh` face (1) — substitution changed nothing | ✅ exit 3 | also hit BY HAND today via a `sed` that never matched |
| `bin/mutate.sh` face (3) — mutation moved the expectation | ✅ exit 5 | `assert`→`refute` on a test file |
| `bin/mutate.sh --self-test` itself | ✅ both guards disabled in turn, each named its arm | scoped mutations; self-test block verified byte-identical |
| `bin/box-sample.sh` `is_num` | ✅ regex → `.*` → `is_num accepted []` | |
| `bin/box-sample.sh` `min_of`/`max_of` | ✅ | dip, empty, ascending, descending |
| `bin/box-sample.sh` serve NOT FOUND ⇒ UNKNOWN | ✅ | pointed at a cwd that cannot match |
| `mix check` `test` stage catches a timeout | ✅ rc=2 `ExUnit.TimeoutError` | and `--trace` rc=0, proving the mode matters |
| `test/fixture_coverage_test.exs` corpus check | ✅ | see LATENT below — required inducing a nested file |
| `box-sample.sh` cleanup cannot fail the measured run | ✅ | run under a forced `set -e`: wrapped command's rc 9 survives, not the cleanup's |
| `with-slot.sh` refuses without a token | ✅ rc 76, nothing run | the wrapped command was written to print if reached; it did not |
| `with-slot.sh` consumes the token | ✅ | second invocation refuses — a token that survives its run is a standing permission, not a slot |
| `mutate.sh` suite path refuses without a token | ✅ rc 76 in 18 ms | and the file is **never touched**: `git diff` empty |
| `mutate.sh --self-test` / `--dry-run` stay ungated | ✅ | they start nothing, so requiring a token would make the cheap path lie |
| `box-sample.sh` UNVERIFIABLE branch, **in a live run** | ✅ | fired unplanned in a 1-sample window: serve pid found, no rss sample landed, no number printed |
| `box-sample.sh` `< 2 samples` warning | ✅ | same run |

## ⚠️ Predicate demonstrated · WIRING NOT

| guard | what is proven | what is NOT |
|---|---|---|
| `serve_hwm_mb` on an unreadable `/proc` | passing a bogus pid returns EMPTY and is refused downstream | a `/proc` read **failing on a pid that WAS found**. Those are different absences on different code paths, and I cannot make the second happen on demand. ⚠️ A live run has now hit the UNVERIFIABLE *branch* (no rss sample landed in a 1-sample window) — that is a DIFFERENT CAUSE reaching the same branch, and it does **not** close this row. |
| `with-slot.sh` green path into `mix check` | the wrapper, the token consume, and the sampler hand-off are exercised with a cheap command | ⛔ never run with `mix check` as the command — that is the queued slot run |
| `mutate.sh` suite path GREEN (token present) | the refusal arm is proven | ⛔ the green arm runs a real suite, so it needs a slot. Not closed by argument. |
| `mix check` self-test stages | both commands verified standalone, exactly as the alias invokes them | ⛔ **never run THROUGH the alias.** Added 2026-08-27; the box was queued, so no `mix check` has executed since. This is a path a healthy day does not exercise until someone runs the gate. |

## ⚠️ LATENT — cannot fire on today's tree, demonstrated by INDUCING the condition

| guard | why latent | how demonstrated |
|---|---|---|
| `mutate.sh` doctest refusal | zero `iex>` in `lib/` today | induced a doctest → rc 5; removed → rc 0 |
| `fixture_coverage_test.exs` glob-vs-walk | all 28 `.exs` are top-level, so a narrowed glob returns the same set | induced `test/nested/probe_test.exs` → narrowed glob CAUGHT; correct glob green |

⭐ Both fire the moment the tree grows the shape they guard — which is exactly when they would
otherwise start lying.

## ⏱ Cheap flags — TIMED, not read

⛔ **A flag that claims to be cheap must be cheap BY POSITION, NOT BY INTENTION.** Measured
elsewhere tonight: a `--self-test` block placed *below* the suite invocation ran ~7 full suites while
its author reported "no BEAM started" in four commit messages. **Reading the file is what let that
ship; only the clock could have caught it.**

| flag | measured | vs a suite (~100 s) |
|---|---|---|
| `mutate.sh --self-test` | 1349 ms | 0.013× |
| `mutate.sh --dry-run` | 315 ms | 0.003× |
| `box-sample.sh --self-test` | 170 ms | 0.002× |
| `with-slot.sh` refusal | 26 ms | 0.0003× |

Positional check beside the clock: `--dry-run` exits at `bin/mutate.sh:213`, the `mix test`
invocation is at `:228`. **Both, because either alone can be satisfied by an accident.**

## ⛔ Known non-guards

- `bin/box-sample.sh` **reports, it does not gate.** Checked rather than assumed: the only exits are
  usage (2), `--self-test` (0/1), and the wrapped command's own status. No exit sits beside a
  headroom test.
- The sampler's teardown is **safe by construction, not safe because `-e` is absent**. Under `set -e`
  a `wait` on a killed child exits 143 and a `kill` on a dead pid exits 1 — a cleanup defect that
  killed two landings elsewhere tonight *after* their suites had passed and *before* anything was
  printed. `|| true` holds regardless of what a later hygiene commit sets.
- ⚠️ **The slot token now gates BOTH callers via one statement** (`bin/require-slot.sh`, sourced by
  `with-slot.sh` and by `mutate.sh`'s suite path). It was gating only the wrapper — **the path of
  least consequence** — while `bin/mutate.sh:228`, the only real `mix test` in this repo, was open.
  Found by enumerating suite-starting lines rather than assuming, with the comment/`echo` hits
  filtered and the raw count shown beside the filtered one.
- ⚠️ **It still gates only what calls it.** `bin/with-slot.sh` cannot see a `mix check` typed
  directly, and that ungated route is exactly how seven silent suites happened elsewhere tonight.
  It is a real interlock against *the moment a waiter goes green*, not a lock on the repo. Recorded
  as a limit rather than presented as coverage.
- ⭐ **Load-bearing vs incidental.** Two of this repo's clean answers tonight were INCIDENTAL and
  have been converted: the teardown was safe only because `-e` was absent (now `|| true`, verified
  under a forced `set -e`), and "not an adopter of the shared health tool" was true of committed
  files while the Sol dispatch is typed by hand — the same runtime read of another tree, invisible
  to any repo grep. Only the `--trace` absence is load-bearing, and only because a positive control
  proved the grep could see its corpus.
- No reachability check exists here, because nothing in this repo gates on a moving host term. That
  is **absence, not design** — if a host-dependent gate is ever added, it needs one, kept in the
  same edit as the gate it guards.

## Next action

Run `mix check` at the next free slot and record whether the two new stages executed. Until that
line exists, the wiring row above stays ⚠️.
