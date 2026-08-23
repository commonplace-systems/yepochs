defmodule Yepochs.UpdateTest do
  use ExUnit.Case, async: true

  alias Yepochs.Error
  alias Yepochs.Test.Updates
  alias Yepochs.Update

  setup_all do
    base = Updates.base("abcdefgh", 100)
    %{base: base}
  end

  describe "decode/1" do
    test "decodes a real yelixer update", %{base: base} do
      assert {:ok, %Update{} = u} = Update.decode(Updates.insert_delta(base, 200, 2, "XY"))
      assert length(u.items) >= 1
    end

    test "returns :malformed_update rather than raising on garbage" do
      assert {:error, %Error{code: :malformed_update, phase: :preflight}} =
               Update.decode(<<0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>)
    end

    test "returns :malformed_update on an empty binary" do
      assert {:error, %Error{code: :malformed_update}} = Update.decode(<<>>)
    end
  end

  describe "owned_intervals/1 — spec §15.4" do
    test "inventories every item interval the update itself defines", %{base: base} do
      {:ok, u} = Update.decode(Updates.insert_delta(base, 200, 2, "XY"))
      # Client 200 authored one 2-character item at clock 0.
      assert Update.owned_intervals(u) == [{200, 0, 2}]
    end

    test "a pure delete owns no item intervals", %{base: base} do
      {:ok, u} = Update.decode(Updates.delete_delta(base, 200, 2, 3))
      assert Update.owned_intervals(u) == []
    end

    test "inventories intervals from MULTIPLE clients, sorted" do
      # yelixer emits clients DESCENDING by id, so a correct inventory has to
      # sort rather than inherit the decoder's order.
      base = Updates.base("abcdefgh", 100)
      r = Yelixer.Types.Text.insert(Updates.replica(base, 200), "t", 2, "XY")
      {:ok, u} = Update.decode(Updates.full(r))

      owned = Update.owned_intervals(u)
      clients = Enum.map(owned, &elem(&1, 0))

      assert 100 in clients and 200 in clients
      assert owned == Enum.sort(owned), "owned_intervals must be sorted, got #{inspect(owned)}"
    end
  end

  describe "owns?/2 — the ownership test strict translation turns on" do
    setup %{base: base} do
      {:ok, u} = Update.decode(Updates.insert_delta(base, 200, 2, "XY"))
      %{u: u}
    end

    test "owns the first clock of an owned interval", %{u: u}, do: assert(Update.owns?(u, {200, 0}))
    test "owns a clock inside an owned interval", %{u: u}, do: assert(Update.owns?(u, {200, 1}))

    test "does NOT own the exclusive end of the interval", %{u: u} do
      refute Update.owns?(u, {200, 2})
    end

    test "does not own a coordinate of a different client", %{u: u} do
      refute Update.owns?(u, {100, 0})
    end
  end

  describe "external_refs/1 — the four identity-bearing sites in §15.6-§15.8" do
    test "reports an insertion origin that the update does not own", %{base: base} do
      {:ok, u} = Update.decode(Updates.insert_delta(base, 200, 2, "XY"))
      fields = u |> Update.external_refs() |> Enum.map(& &1.field) |> Enum.uniq()
      assert :origin in fields or :right_origin in fields
    end

    test "reports delete-set coordinates as external references", %{base: base} do
      {:ok, u} = Update.decode(Updates.delete_delta(base, 200, 2, 3))
      deletes = u |> Update.external_refs() |> Enum.filter(&(&1.field == :delete))
      assert deletes != []
      # The deleted characters belong to client 100, the base author.
      assert Enum.all?(deletes, fn d -> elem(d.ref, 0) == 100 end)
    end

    test "does NOT report references the update owns", %{base: base} do
      # One update inserting two adjacent runs: the second anchors on the first.
      r = Yelixer.Types.Text.insert(Updates.replica(base, 200), "t", 2, "XY")
      r = Yelixer.Types.Text.insert(r, "t", 4, "ZW")
      {:ok, u} = Update.decode(Updates.delta(r, base))

      owned = Update.owned_intervals(u)
      assert length(owned) >= 1

      for %{ref: ref} <- Update.external_refs(u) do
        refute Update.owns?(u, ref)
      end
    end

    test "a named root parent is not an identity reference and is never reported", %{base: base} do
      {:ok, u} = Update.decode(Updates.full(base))
      refute Enum.any?(Update.external_refs(u), &(&1.field == :parent))
    end

    test "an update deleting its OWN insertion reports no external delete ref", %{base: base} do
      # §15.8: a clock inside an interval the update owns is PRESERVED, not
      # translated. Deleting characters this update itself inserted must not
      # produce a bridge lookup.
      r = Yelixer.Types.Text.insert(Updates.replica(base, 200), "t", 2, "XYZW")
      r = Yelixer.Types.Text.delete(r, "t", 3, 2)
      {:ok, u} = Update.decode(Updates.delta(r, base))

      assert Update.owned_intervals(u) != []
      deletes = Enum.filter(Update.external_refs(u), &(&1.field == :delete))

      assert Enum.all?(deletes, fn d -> elem(d.ref, 0) != 200 end),
             "owned clocks must be subtracted from delete ranges, got #{inspect(deletes)}"
    end

    test "a delete spanning BOTH owned and external clocks reports only the external part",
         %{base: base} do
      # Spec §28.2 fixture 4. Deleting across the seam between inserted text and
      # the base document must split the range, not pass it through whole.
      r = Yelixer.Types.Text.insert(Updates.replica(base, 200), "t", 2, "XY")
      r = Yelixer.Types.Text.delete(r, "t", 1, 3)
      {:ok, u} = Update.decode(Updates.delta(r, base))

      deletes = Enum.filter(Update.external_refs(u), &(&1.field == :delete))
      clients = deletes |> Enum.map(&elem(&1.ref, 0)) |> Enum.uniq()

      assert 100 in clients, "the base author's deleted clock must still need mapping"
      refute 200 in clients, "the update's own inserted clocks must be preserved, not mapped"

      for %{ref: ref, length: len} <- deletes, n <- 0..(len - 1) do
        {c, k} = ref
        refute Update.owns?(u, {c, k + n})
      end
    end

    test "is deterministically ordered across several refs and clients", %{base: base} do
      r = Yelixer.Types.Text.insert(Updates.replica(base, 200), "t", 2, "XY")
      r = Yelixer.Types.Text.delete(r, "t", 5, 2)
      r = Yelixer.Types.Text.delete(r, "t", 0, 1)
      {:ok, u} = Update.decode(Updates.delta(r, base))

      refs = Update.external_refs(u)
      assert length(refs) > 1, "need several refs for ordering to be observable"
      assert refs == Enum.sort_by(refs, &{&1.field, &1.ref})
    end
  end
end
