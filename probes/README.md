# Probes

Measurement scripts that need the **yelixer** substrate. They live outside `lib/` and outside the
test suite on purpose: Tier 0 of `yepochs` has **no dependency on yelixer at all**
(see `../docs/design/0001-build-order-and-gate.md`), and these must not become the reason it grows
one.

## Running them

Create a throwaway mix project with yelixer as a path dep — do **not** run these inside `~/yelixer`,
which would write a `mix.lock` into a repo this one does not own:

```elixir
# mix.exs
defp deps, do: [{:yelixer, path: "/home/jes/yelixer"}]
```

Copy `.tool-versions` from yelixer, then `mix deps.get && mix run <probe>.exs`.

## What is here

| Probe | Question |
|---|---|
| `encode_determinism_cases.exs` | Is `encode_update/1` a pure function of one fixed `Doc` term? Which hand-picked scenarios diverge across apply-order? |
| `encode_determinism_sweep.exs` | All 676 concurrent-delete-pair combinations over an 8-character base, classified by the geometric relationship of the two ranges. |

Findings are written up in `../docs/design/0002-encode-determinism.md`.

⚠️ **`encode_delete_set/1` takes a `%DeleteSet{}`, not a `%Doc{}`.** `Text.insert/4` and
`Text.delete/4` return a bare `%Doc{}`; `Encoding.apply_update/2` returns `{:ok, doc}`.

⛔ **Counting blocks via `doc.store.clients` alone is a blind instrument** — items can sit in
`doc.store.client_pending` and will not be counted, which produced a nonsense `blocks=3/0` reading
in an early version of the cases probe. Byte comparison of `encode_update/1` is the reliable
measurement; block counts are for diagnosis only.
