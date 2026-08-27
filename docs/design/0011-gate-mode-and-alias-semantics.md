# 0011 — The gating mode, and what a Mix alias does with a red stage

**Status:** measured · **Date:** 2026-08-27 · **Evidence:** reproduced in-tree and in a scratch
project; whole logs, not filtered reads

## 1. The `--trace` class does not apply here — and the zero has a control

`mix test --trace` sets every per-test timeout to `:infinity`
(`ex_unit/lib/ex_unit/runner.ex:564`, unconditional — an explicit `--timeout` cannot override it,
because the tag is never consulted) and forces `--max-cases 1`. A gate whose verdict comes from a
traced run is blind to timeouts **and** to contention-sensitive failures.

**Checked:** `grep -rn -- "--trace"` across the 80 tracked source files ⇒ **zero hits**. The
`check:` alias runs plain `mix test`.

⭐ **The zero is only evidence because a positive control ran on the same instrument and corpus:**
`"mix test"` returned 11 hits. Absence and a blind instrument share an observable; the control
tells them apart.

**Demonstrated in-tree** — `@tag timeout: 100` against `Process.sleep(400)`:

| run | rc | result |
|---|---|---|
| `mix test` | 2 | `** (ExUnit.TimeoutError) test timed out after 100ms` |
| `mix test --trace` | 0 | 1 test, 0 failures |

## 2. ⛔ A Mix alias does NOT short-circuit on a failing stage

`check: ["format --check-formatted", "compile --warnings-as-errors", "test", "cmd MIX_ENV=dev mix dialyzer"]`

Green control and red arm, one project, differing by one tag:

```
GREEN  rc=0   1 test, 0 failures   STAGE_AFTER_TEST_RAN
RED    rc=2   1 test, 1 failure    STAGE_AFTER_TEST_RAN   ← ran anyway
```

✅ **The verdict is sound:** rc stayed 2 although the *later* stage exited 0 — a passing stage does
not mask an earlier red.
⛔ **But the later stage executes.** A red suite still spawns dialyzer: minutes and hundreds of MB
after the answer is already known.

## 3. ⭐⭐ Method note — two vacuous runs that matched the prediction exactly

Predicted for the red arm: non-zero rc, and no post-test stage. Got exactly that **twice**, from
runs where the test stage never executed:

- `rc=126` — `No version is set for command mix`. No `.tool-versions` in the scratch project. **Mix
  never started.**
- `rc=1` — `Expected one or more files/patterns to be given to mix format`. No `.formatter.exs`.
  **Died at stage 1, never reached `test`.**

⛔ Both halves of the prediction matched both times, and both runs were vacuous. The grep filter
printed nothing for the test-count line and nothing for `TimeoutError` — **and "nothing" is also
what a pass looks like through that filter.**

⭐ **What broke it: reading the WHOLE log instead of a filtered view.** Capture whole, then filter
the file.
⭐ **And the green control is what made the red mean anything** — `STAGE_AFTER_TEST_RAN` in the red
arm was only interpretable because it had been watched appearing in a green arm on the same project.

⇒ **A red that agrees with you is the easiest one to accept without checking which arm produced it.**
The right exit code from the wrong mechanism is still the wrong answer.

## 4. Not adopted, with the reason stated

The two-run landing design (plain run = verdict, traced run = arm names; **disagreement ⇒
timing-or-concurrency class, not a flake**) is sound and its discriminator is real. **Not adopted
today:** it doubles a 629-test + 12-property suite, and the box is under a memory hold. Recorded as
a wake condition in `README.md` rather than left to memory.
