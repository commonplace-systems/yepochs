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
  alias Yelixer.BlockStore
  alias Yelixer.Types.Array
  alias Yelixer.Types.Text
  alias Yelixer.Types.XMLElement
  alias Yelixer.Types.XMLText
  alias Yelixer.Types.YMap
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

  # ------------------------------------------------------------------
  # Map and array concurrency — the gap `docs/design/0009` declared, and
  # `commonplace-doc` correctly refused to let stand as "asserted".
  # ------------------------------------------------------------------

  defp materialized(%Doc{} = d) do
    {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
    m
  end

  defp max_item_length(%Doc{store: store}) do
    store |> BlockStore.all_items() |> Enum.map(& &1.length) |> Enum.max(fn -> 0 end)
  end

  @doc false
  def map_and_array_constructions do
    [
      {"array 8 values in one call",
       fn -> Array.insert(Doc.new(client_id: 100), "a", 0, ~w(a b c d e f g h)) end},
      {"array 8 push calls",
       fn -> Enum.reduce(1..8, Doc.new(client_id: 100), &Array.push(&2, "a", ["#{&1}"])) end},
      {"array of integers",
       fn -> Array.insert(Doc.new(client_id: 100), "a", 0, [1, 2, 3, 4, 5, 6, 7, 8]) end},
      {"array of long strings",
       fn -> Array.insert(Doc.new(client_id: 100), "a", 0, ["aaaaaaaa", "bbbbbbbb"]) end},
      {"map 8 keys",
       fn -> Enum.reduce(1..8, Doc.new(client_id: 100), &YMap.set(&2, "m", "k#{&1}", "v")) end},
      {"map long value",
       fn -> YMap.set(Doc.new(client_id: 100), "m", "k", "aaaaaaaaaaaaaaaa") end},
      {"map overwritten 8 times",
       fn -> Enum.reduce(1..8, Doc.new(client_id: 100), &YMap.set(&2, "m", "k", "v#{&1}")) end}
    ]
  end

  test "map and array items are UNSPLITTABLE, which is why their concurrency cannot reorder" do
    # ⭐ The mechanism, not a corpus observation. Text is order-dependent under
    # concurrent deletes because `"abcdefgh"` is ONE item of length 8 and the
    # deletes SPLIT it — split boundaries depend on arrival order. Map and array
    # items are length 1, so there is nothing to split.
    #
    # ⛔ This test fails if the substrate ever consolidates map/array content
    # into multi-length blocks. At that point map concurrency COULD become
    # order-dependent and 0009's conclusion must be re-measured rather than
    # inherited — the limit must not outlive its cause.
    for {name, build} <- map_and_array_constructions() do
      assert max_item_length(materialized(build.())) == 1,
             "#{name} now holds a multi-length item — map/array content has become splittable, " <>
               "so the order-independence conclusion in docs/design/0009 must be RE-MEASURED"
    end

    # ⭐ Control on the instrument: it must be able to SEE a length > 1, or the
    # assertions above are satisfied by a measurement that always returns 1.
    assert max_item_length(materialized(Text.insert(Doc.new(client_id: 100), "t", 0, "abcdefgh"))) ==
             8

    assert max_item_length(
             materialized(XMLText.insert(Doc.new(client_id: 100), "x", 0, "abcdefgh"))
           ) == 8
  end

  test "concurrent map and array operations never reorder the encoding, let alone the snapshot" do
    base_map =
      materialized(Enum.reduce(~w(a b c), Doc.new(client_id: 100), &YMap.set(&2, "m", &1, "v0")))

    base_arr = materialized(Array.insert(Doc.new(client_id: 100), "a", 0, ~w(p q r s)))

    map_ops =
      for(k <- ~w(a b c d), v <- ~w(x y), do: &YMap.set(&1, "m", k, v)) ++
        for(k <- ~w(a b c), do: &YMap.delete(&1, "m", k))

    arr_ops =
      for(i <- 0..4, do: &Array.insert(&1, "a", i, ["N"])) ++
        for(i <- 0..3, l <- 1..2, i + l <= 4, do: &Array.delete(&1, "a", i, l))

    for {base, ops} <- [{base_map, map_ops}, {base_arr, arr_ops}] do
      base_u = Encoding.encode_update(base)

      apply_op = fn client, f ->
        {:ok, d} = Encoding.apply_update(Doc.new(client_id: client), base_u)
        Encoding.encode_update(f.(d))
      end

      for f1 <- ops, f2 <- ops do
        u1 = apply_op.(200, f1)
        u2 = apply_op.(300, f2)

        forward = integrate([base_u, u1, u2])
        reverse = integrate([base_u, u2, u1])

        # ⚠️ Stronger than the text case: the RAW ENCODING already agrees, so
        # snapshot agreement follows rather than being an extra fact.
        assert Encoding.encode_update(forward) == Encoding.encode_update(reverse)
        assert same_snapshot?(forward, reverse)
      end
    end
  end

  # ------------------------------------------------------------------
  # THREE concurrent authors, and the nested-type case that turns out not
  # to be a gap at all. Both were named as uncovered in 0009's Limits.
  # ------------------------------------------------------------------

  @three_author_ranges [{0, 3}, {2, 3}, {4, 3}, {1, 2}, {5, 2}, {3, 4}]

  defp orderings([a, b, c]) do
    [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]]
  end

  test "order-independence survives THREE concurrent authors, all six arrival orders" do
    # ⭐ The two-author sweep left ">2 authors" as a named gap. A third author
    # multiplies the orderings from 2 to 6, so a split boundary has more ways to
    # land differently — this is where an order-dependent traversal would show.
    rows =
      for {i1, l1} <- @three_author_ranges,
          {i2, l2} <- @three_author_ranges,
          {i3, l3} <- @three_author_ranges do
        updates = [deletion(200, i1, l1), deletion(300, i2, l2), deletion(400, i3, l3)]

        docs = Enum.map(orderings(updates), fn order -> integrate([base_update() | order]) end)

        %{
          discriminating:
            docs |> Enum.map(&Encoding.encode_update/1) |> Enum.uniq() |> length() > 1,
          converged: docs |> Enum.map(&Text.to_string(&1, "t")) |> Enum.uniq() |> length() == 1,
          snapshots_agree:
            docs
            |> Enum.map(fn d ->
              {:ok, s} = Snapshotter.snapshot(d)
              {s.update, s.derivation.spans}
            end)
            |> Enum.uniq()
            |> length() == 1
        }
      end

    discriminating = Enum.filter(rows, & &1.discriminating)

    assert length(discriminating) > 100,
           "only #{length(discriminating)} of #{length(rows)} triples have order-dependent raw " <>
             "encoding — the instrument cannot see what it is measuring"

    assert Enum.all?(rows, & &1.converged), "observable text diverged — a CRDT convergence bug"

    assert Enum.all?(discriminating, & &1.snapshots_agree),
           "a three-author triple produced different snapshots under different arrival orders"
  end

  test "nested types are not an uncovered gap — such a document has no snapshot to be ordered" do
    # ⭐ 0009 listed "nested types" as uncovered. It is not a gap: an epoch
    # boundary IS a snapshot, and a document holding a nested-type instance
    # cannot be snapshotted at all, so no opener can exist over one. The
    # question does not arise rather than being unanswered.
    nested = [
      Doc.new(client_id: 100)
      |> XMLElement.new_element("e", "p")
      |> XMLElement.insert_child("e", 0, :text),
      Doc.new(client_id: 100)
      |> Text.insert("t", 0, "hi")
      |> XMLElement.new_element("e", "p")
      |> XMLElement.insert_child("e", 0, :text)
    ]

    for doc <- nested do
      assert {:error, error} = Snapshotter.snapshot(materialized(doc))
      assert error.code == :unsupported_content
      assert error.details.cause == :nested_type_children
    end

    # ⛔ CONTROL: a document with no nested type MUST snapshot, or the refusals
    # above prove nothing about nested types specifically.
    assert {:ok, _} =
             Snapshotter.snapshot(
               materialized(Text.insert(Doc.new(client_id: 100), "t", 0, "hi"))
             )
  end
end
