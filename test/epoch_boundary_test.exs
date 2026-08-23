defmodule Yepochs.EpochBoundaryTest do
  @moduledoc """
  ⭐ **The hinge, in executable form: what does and does not create a Yepoch.**

  Spec §6.3: *"Ordinary edits within a history do not create new Yepochs.
  Deterministic re-authoring does."*

  ⛔ **The plausible tightening — "every fork mints a Yepoch" — is wrong, and it
  forecloses things.** A fork that merely branches over the same Yjs history
  keeps its identity space: its coordinates stay comparable, and merging it back
  is ordinary CRDT convergence with no bridge in sight. A fork that **replays
  into fresh identities** mints a new Yepoch, and that one genuinely cannot be
  merged back cheaply — which is correct, not a limitation.

  ⚠️ The distinction is not decoration. Downstream, an epoch id binds into a
  content address; if every fork minted one, identical content would hash
  differently in two lineages and push-back would die by the field meant to make
  it safe. **This file exists so the rule cannot be tidied into the simpler,
  wrong version without something going red.**

  §6.3 states the rule affirmatively and never states the negative. This is the
  negative.
  """
  use ExUnit.Case, async: true

  alias Yelixer.BlockStore
  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Text
  alias Yepochs.Snapshotter

  defp materialized(%Doc{} = d) do
    {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
    m
  end

  defp replica(%Doc{} = base, client) do
    d = Doc.new(client_id: client)
    {:ok, d} = Encoding.apply_update(d, Encoding.encode_update(base))
    d
  end

  defp delta(%Doc{} = doc, %Doc{} = since),
    do: Encoding.encode_diff(doc, BlockStore.state_vector(since.store))

  # Every live item's identity, so two documents can be asked whether they are
  # talking about the SAME items rather than merely equal-looking content.
  defp identities(%Doc{store: store}) do
    store
    |> BlockStore.all_items()
    |> Enum.reject(& &1.deleted)
    |> Enum.map(&{&1.id.client, &1.id.clock, &1.length})
    |> Enum.sort()
  end

  describe "an ordinary fork does NOT create a Yepoch" do
    setup do
      base = materialized(Text.insert(Doc.new(client_id: 100), "t", 0, "hello"))
      %{base: base}
    end

    test "two branches by ordinary editing converge with no bridge and no translation",
         %{base: base} do
      left = Text.insert(replica(base, 200), "t", 5, " left")
      right = Text.insert(replica(base, 300), "t", 0, "right ")

      # Plain Yjs merge. Nothing from this library is on the path.
      {:ok, merged} = Encoding.apply_update(base, delta(left, base))
      {:ok, merged} = Encoding.apply_update(merged, delta(right, base))

      assert Text.to_string(merged, "t") == "right hello left"

      # ⭐ The load-bearing assertion: the items each branch authored are present
      # in the merge under THE SAME coordinates. One identity space, so a
      # coordinate authored on either side still denotes the same item.
      for branch <- [left, right] do
        authored = identities(branch) -- identities(base)
        assert authored != [], "premise: this branch must have authored something"

        assert Enum.all?(authored, &(&1 in identities(merged))),
               "a branch's item identities must survive the merge unchanged — if they do not, " <>
                 "the branches were not in one Yepoch after all"
      end
    end

    test "convergence does not depend on merge order", %{base: base} do
      left = Text.insert(replica(base, 200), "t", 5, " left")
      right = Text.insert(replica(base, 300), "t", 0, "right ")

      {:ok, a} = Encoding.apply_update(base, delta(left, base))
      {:ok, a} = Encoding.apply_update(a, delta(right, base))
      {:ok, b} = Encoding.apply_update(base, delta(right, base))
      {:ok, b} = Encoding.apply_update(b, delta(left, base))

      assert Text.to_string(a, "t") == Text.to_string(b, "t")
      assert identities(a) == identities(b)
    end
  end

  describe "re-authoring DOES create a Yepoch" do
    test "the same content lands at different identities, so raw coordinates stop denoting" do
      # Two authors, so the derived document cannot reuse every source client id
      # and the remapping is real rather than an identity mapping.
      base = materialized(Text.insert(Doc.new(client_id: 100), "t", 0, "hello"))
      second = Text.insert(replica(base, 200), "t", 5, "!!")
      {:ok, merged} = Encoding.apply_update(base, Encoding.encode_update(second))
      origin = materialized(merged)

      {:ok, snapshot} = Snapshotter.snapshot(origin)
      {:ok, derived} = Encoding.apply_update(Doc.new(client_id: 0), snapshot.update)

      assert Text.to_string(origin, "t") == Text.to_string(derived, "t"),
             "premise: re-authoring preserves the observable value"

      refute identities(origin) == identities(derived),
             "⛔ if the identities matched, this would not be a new identity space and the " <>
               "whole bridge apparatus would be unnecessary"

      # ⭐ Invariant 1 made concrete: a coordinate from the origin does not
      # denote the same item in the derived document. THIS is what a Yepoch
      # boundary means, and it is what an ordinary fork does not do.
      assert Enum.any?(snapshot.derivation.spans, fn s ->
               {s.left_client, s.left_clock} != {s.right_client, s.right_clock}
             end),
             "the derivation must record a real remapping, or nothing was re-identified"
    end

    test "⛔ a Yepoch boundary is NOT detectable by inspecting the documents" do
      # ⛔⛔ THIS TEST EXISTS BECAUSE I ASSERTED THE OPPOSITE AND IT FAILED.
      #
      # I wrote "a re-authoring REPLACES the base's identities" and it is false
      # for a SINGLE-AUTHOR document. The deterministic minter re-authors under
      # the smallest client id present; with one author it reuses it, and the
      # clocks land identically. Measured: the snapshot update is BYTE-IDENTICAL
      # to the source encoding.
      #
      # ⇒ Two documents can be byte-for-byte equal and still belong to DIFFERENT
      # Yepochs, because a Yepoch is a namespace, not a property of the content.
      # Nothing in the artifact distinguishes them.
      #
      # ⭐ That is the whole argument for a CARRIED epoch id, and it is stronger
      # than any argument from convenience: the boundary is not merely awkward to
      # detect from the data, it is ABSENT from the data.
      base = materialized(Text.insert(Doc.new(client_id: 100), "t", 0, "hello"))

      {:ok, snapshot} = Snapshotter.snapshot(base)
      {:ok, derived} = Encoding.apply_update(Doc.new(client_id: 0), snapshot.update)

      assert identities(base) == identities(derived),
             "premise: a single-author re-authoring reuses the same coordinates"

      assert snapshot.update == Encoding.encode_update(base),
             "premise: and produces byte-identical output"

      assert Enum.all?(snapshot.derivation.spans, fn s ->
               {s.left_client, s.left_clock} == {s.right_client, s.right_clock}
             end),
             "so the derivation is the identity mapping — a real bridge over a real boundary " <>
               "whose every span happens to be an identity span"

      # ⭐ The boundary is real regardless: `derived` is a new namespace whose
      # coordinates coincide with the old one's. A later divergence in either
      # lineage makes the same coordinate mean two different things.
      after_origin = Text.insert(replica(base, 200), "t", 5, "A")
      after_derived = Text.insert(replica(derived, 200), "t", 0, "B")

      collision =
        Enum.filter(identities(after_origin) -- identities(base), fn id ->
          id in (identities(after_derived) -- identities(derived))
        end)

      assert collision != [],
             "⛔ the two lineages must be able to mint the SAME coordinate for DIFFERENT " <>
               "content — that is invariant 1's hazard, and it is why the namespaces must be " <>
               "distinguished by a carried id rather than by inspection"
    end

    test "an ordinary fork and a re-authoring differ by IDENTITY RETENTION, not by name" do
      # ⭐ Where the source is multi-author, the difference IS visible — a fork
      # retains the base's identities, a re-authoring does not. Stated with the
      # multi-author precondition that the previous test proves is required.
      base = materialized(Text.insert(Doc.new(client_id: 100), "t", 0, "hello"))
      second = Text.insert(replica(base, 200), "t", 5, "!!")
      {:ok, merged} = Encoding.apply_update(base, Encoding.encode_update(second))
      origin = materialized(merged)

      forked = Text.insert(replica(origin, 300), "t", 5, "?")
      {:ok, snapshot} = Snapshotter.snapshot(origin)
      {:ok, reauthored} = Encoding.apply_update(Doc.new(client_id: 0), snapshot.update)

      origin_ids = identities(origin)

      assert Enum.all?(origin_ids, &(&1 in identities(forked))),
             "a fork RETAINS the origin's identities — same Yepoch"

      refute Enum.all?(origin_ids, &(&1 in identities(reauthored))),
             "a multi-author re-authoring REPLACES them — new Yepoch"
    end
  end
end
