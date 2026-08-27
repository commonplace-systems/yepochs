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

## ⚠️ Predicate demonstrated · WIRING NOT

| guard | what is proven | what is NOT |
|---|---|---|
| `serve_hwm_mb` on an unreadable `/proc` | passing a bogus pid returns EMPTY and is refused downstream | a `/proc` read **failing on a pid that WAS found**. Those are different absences on different code paths, and I cannot make the second happen on demand. |
| `mix check` self-test stages | both commands verified standalone, exactly as the alias invokes them | ⛔ **never run THROUGH the alias.** Added 2026-08-27; the box was queued, so no `mix check` has executed since. This is a path a healthy day does not exercise until someone runs the gate. |

## ⚠️ LATENT — cannot fire on today's tree, demonstrated by INDUCING the condition

| guard | why latent | how demonstrated |
|---|---|---|
| `mutate.sh` doctest refusal | zero `iex>` in `lib/` today | induced a doctest → rc 5; removed → rc 0 |
| `fixture_coverage_test.exs` glob-vs-walk | all 28 `.exs` are top-level, so a narrowed glob returns the same set | induced `test/nested/probe_test.exs` → narrowed glob CAUGHT; correct glob green |

⭐ Both fire the moment the tree grows the shape they guard — which is exactly when they would
otherwise start lying.

## ⛔ Known non-guards

- `bin/box-sample.sh` **reports, it does not gate.** Checked rather than assumed: the only exits are
  usage (2), `--self-test` (0/1), and the wrapped command's own status. No exit sits beside a
  headroom test.
- No reachability check exists here, because nothing in this repo gates on a moving host term. That
  is **absence, not design** — if a host-dependent gate is ever added, it needs one, kept in the
  same edit as the gate it guards.

## Next action

Run `mix check` at the next free slot and record whether the two new stages executed. Until that
line exists, the wiring row above stays ⚠️.
