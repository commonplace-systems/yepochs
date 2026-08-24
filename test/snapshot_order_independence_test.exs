defmodule Yepochs.SnapshotOrderIndependenceTest do
  @moduledoc """
  ⭐ **Feasibility gate for deterministic epoch-token minting** (jes, 15:40:50Z:
  a boundary epoch token is minted *"deterministic if possible"*).

  The token itself is trivially deterministic — it is a hash of chosen inputs.
  **The question that decides feasibility is whether the thing it NAMES is
  deterministic:** do two nodes replaying the same commit set in *different
  orders* derive the same snapshot? If not, one token names two documents and
  federation forks on every epoch change.

  ⛔ The reason to doubt it: `Encoding.encode_update/1` **is** path-dependent
  under concurrent deletes — measured over these same 676 pairs, and
  independently by `commonplace-merkle-crdt`.

  ⚠️ **Corpus discipline.** A pair whose raw encoding does not vary cannot
  discriminate; a suite of those would report a confident vacuous pass. This
  test therefore asserts a **floor on the discriminating count** before it
  believes the result — see `probes/snapshot_order_independence.exs`.
  """
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Text
  alias Yepochs.Snapshotter

  # Every pair of concurrent deletes over an 8-character base: 26 ranges squared.
  @ranges for i <- 0..7, l <- 1..4, i + l <= 8, do: {i, l}

  defp base_update do
    Encoding.encode_update(Text.insert(Doc.new(client_id: 100), "t", 0, "abcdefgh"))
  end

  defp deletion(client, index, length) do
    {:ok, d} = Encoding.apply_update(Doc.new(client_id: client), base_update())
    Encoding.encode_update(Text.delete(d, "t", index, length))
  end

  defp integrate(updates) do
    Enum.reduce(updates, Doc.new(client_id: 1), fn u, d ->
      {:ok, d} = Encoding.apply_update(d, u)
      d
    end)
  end

  # ⭐ Extracted so a control can prove it detects a difference. Mutation
  # testing caught the earlier inline version: rewriting it to compare a
  # document against ITSELF left every assertion green, because nothing in the
  # suite ever asked it to say "different".
  defp same_snapshot?(%Doc{} = left, %Doc{} = right) do
    case {Snapshotter.snapshot(left), Snapshotter.snapshot(right)} do
      {{:ok, a}, {:ok, b}} -> a.update == b.update and a.derivation.spans == b.derivation.spans
      {{:error, _}, {:error, _}} -> true
      _ -> false
    end
  end

  defp sweep do
    for {i1, l1} <- @ranges, {i2, l2} <- @ranges do
      u1 = deletion(200, i1, l1)
      u2 = deletion(300, i2, l2)

      forward = integrate([base_update(), u1, u2])
      reverse = integrate([base_update(), u2, u1])

      %{
        discriminating: Encoding.encode_update(forward) != Encoding.encode_update(reverse),
        converged: Text.to_string(forward, "t") == Text.to_string(reverse, "t"),
        same_snapshot: same_snapshot?(forward, reverse)
      }
    end
  end

  test "the comparison can say DIFFERENT — control on the instrument itself" do
    # ⛔ Without this, `same_snapshot?/2` could compare a document to itself and
    # the sweep would report a confident, meaningless pass.
    one = integrate([base_update(), deletion(200, 0, 3)])
    other = integrate([base_update(), deletion(200, 4, 3)])

    refute same_snapshot?(one, other),
           "two genuinely different documents must not compare as the same snapshot"

    assert same_snapshot?(one, one), "and a document must compare equal to itself"
  end

  test "snapshotting is arrival-order independent where encoding is not" do
    rows = sweep()

    # ⛔ POSITIVE CONTROL FIRST. Without a floor here the assertion below passes
    # vacuously on a corpus that never exercised path-dependence at all — which
    # is exactly how the first version of the totality matrix read 100% green
    # while a no-op would have satisfied it.
    discriminating = Enum.filter(rows, & &1.discriminating)

    assert length(discriminating) > 200,
           "only #{length(discriminating)} of #{length(rows)} pairs have order-dependent raw " <>
             "encoding — the instrument cannot see what it is measuring"

    assert Enum.all?(rows, & &1.converged),
           "observable text diverged by arrival order — that would be a CRDT convergence bug, " <>
             "not a snapshot determinism one"

    disagreements = Enum.reject(discriminating, & &1.same_snapshot)

    assert disagreements == [],
           "#{length(disagreements)} of #{length(discriminating)} order-dependent pairs produced " <>
             "different snapshots. ⛔ Deterministic epoch-token minting is NOT feasible from a " <>
             "locally materialized Doc, and jes must be told with this measurement."
  end
end
