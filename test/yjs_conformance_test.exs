defmodule Yepochs.YjsConformanceTest do
  @moduledoc """
  Spec r2 §28.4 — conformance vectors authored by **upstream `yjs` 13.6.32**,
  not by yelixer.

  ⭐ **Every other test in this repo builds its documents through yelixer**, which
  puts yelixer's encoder on both sides of the comparison. These cases put a
  different implementation on one side: the bytes are foreign, and the question
  is whether this library's operations work on updates it did not author.

  See `test/fixtures/yjs-v1/README.md` for provenance and for what a green run
  here does *not* mean.
  """
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Text
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Snapshotter
  alias Yepochs.Update

  @fixtures Path.join(__DIR__, "fixtures/yjs-v1")

  defp cases do
    @fixtures
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(@fixtures, &1)))
    |> Enum.sort()
  end

  defp updates(name) do
    Path.join([@fixtures, name, "updates.hex"])
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      assert Regex.match?(~r/^[0-9a-f]+$/, line), "fixture line is not lowercase hex: #{line}"
      Base.decode16!(line, case: :lower)
    end)
  end

  # The view files are a fixed one-key shape; parsing them with a regex avoids
  # adding a JSON dependency to a library that needs none.
  defp expected_text(name) do
    json = File.read!(Path.join([@fixtures, name, "expected_view.json"]))
    [_, text] = Regex.run(~r/"text"\s*:\s*"([^"]*)"/, json)
    text
  end

  defp assemble(name) do
    Enum.reduce(updates(name), Doc.new(client_id: 1), fn u, d ->
      {:ok, d} = Encoding.apply_update(d, u)
      d
    end)
  end

  test "the corpus is present and non-empty — a positive control on the fixture loader" do
    # Without this, a mis-pathed @fixtures would make every case below vacuous:
    # File.ls! on a missing dir raises, but an EMPTY dir would silently pass a
    # for-comprehension over zero cases.
    assert length(cases()) >= 5, "expected the upstream corpus, got #{inspect(cases())}"

    for name <- cases() do
      assert updates(name) != [], "#{name} has no updates"
    end
  end

  describe "decoding foreign bytes" do
    test "every upstream-authored update decodes through Yepochs.Update" do
      for name <- cases(), update <- updates(name) do
        assert {:ok, %Update{}} = Update.decode(update),
               "#{name}: an upstream-authored update failed to decode"
      end
    end

    test "assembling upstream updates reproduces the view upstream computed" do
      for name <- cases() do
        assert Text.to_string(assemble(name), "t") == expected_text(name),
               "#{name}: view mismatch against upstream's own expected_view.json"
      end
    end

    test "owned intervals and external refs are inventoried on foreign updates" do
      for name <- cases(), update <- updates(name) do
        {:ok, u} = Update.decode(update)
        owned = Update.owned_intervals(u)
        refs = Update.external_refs(u)

        # Whatever an update defines, it must not also report as external.
        for %{ref: ref} <- refs,
            do: refute(Update.owns?(u, ref), "#{name}: owned ref reported external")

        assert is_list(owned)
      end
    end
  end

  describe "operating on documents assembled from foreign bytes" do
    test "snapshotting preserves the observable state upstream expects" do
      for name <- cases() do
        doc = assemble(name)
        expected = expected_text(name)

        case Snapshotter.snapshot(doc, []) do
          {:ok, s} ->
            {:ok, out} = Encoding.apply_update(Doc.new(client_id: 9), s.update)

            assert Text.to_string(out, "t") == expected,
                   "#{name}: snapshot lost or altered observable state"

          {:error, e} ->
            flunk("#{name}: snapshot refused a document upstream considers valid: #{inspect(e)}")
        end
      end
    end

    @doc false
    # Cases whose assembled document has NO tombstones. Their edits translate
    # strictly; the rest re-author, for the reason documented below.
    @tombstone_free ["001-concurrent-inserts-same-position", "002-sequential-inserts-two-authors"]

    test "an edit over TOMBSTONE-FREE foreign state takes the STRICT path" do
      for name <- @tombstone_free do
        doc = assemble(name)
        {:ok, s} = Snapshotter.snapshot(doc, [])
        {:ok, bridge} = Bridge.attach(s.derivation, "origin", "derived", Algorithm.snapshot())

        update =
          Encoding.encode_diff(
            Text.insert(doc, "t", 0, "Z"),
            Yelixer.BlockStore.state_vector(doc.store)
          )

        assert {:ok, _} = Yepochs.translate(update, bridge, :left, []),
               "#{name}: strict translation should succeed over foreign bytes with no tombstones"
      end
    end

    test "⛔ the LOW-LEVEL translate/4 still refuses tombstoned foreign state — ruling 3" do
      # `translate/4` receives no endpoint states, so it cannot PROVE a historical
      # range is already satisfied at the destination. Ruling 3 keeps it
      # conservative in exactly that case: it must fail rather than guess.
      # `cross/5`, which has the states, omits the checked ranges and stays on
      # the strict path — asserted in the test below.
      for name <- cases() -- @tombstone_free do
        doc = assemble(name)
        {:ok, s} = Snapshotter.snapshot(doc, [])
        {:ok, bridge} = Bridge.attach(s.derivation, "origin", "derived", Algorithm.snapshot())

        update =
          Encoding.encode_diff(
            Text.insert(doc, "t", 0, "Z"),
            Yelixer.BlockStore.state_vector(doc.store)
          )

        assert {:error, %{code: :missing_operation_target} = err} =
                 Yepochs.translate(update, bridge, :left, [])

        assert Enum.any?(err.details.failures, &(&1.field == :delete)),
               "#{name}: expected the DELETE SET to be what strict translation cannot cover"
      end
    end

    test "a foreign edit crosses a bridge built from a foreign snapshot" do
      for name <- cases() do
        doc = assemble(name)
        {:ok, s} = Snapshotter.snapshot(doc, [])
        {:ok, target} = Encoding.apply_update(Doc.new(client_id: 9), s.update)
        {:ok, bridge} = Bridge.attach(s.derivation, "origin", "derived", Algorithm.snapshot())

        # An edit authored ON TOP of the foreign state, crossed to the snapshot.
        edited = Text.insert(doc, "t", 0, "Z")
        update = Encoding.encode_diff(edited, Yelixer.BlockStore.state_vector(doc.store))

        assert {:ok, c} =
                 Yepochs.cross(bridge, update, doc, target,
                   from: :left,
                   author: 4242,
                   receipt_ref: "conformance-#{name}"
                 )

        {:ok, out} = Encoding.apply_update(target, c.update)

        assert Text.to_string(out, "t") == "Z" <> expected_text(name),
               "#{name}: crossing an edit over foreign state gave the wrong result (#{c.mode})"

        # ⭐ Ruling 3: EVERY case now takes the strict path. Before checked
        # omission the three cases carrying pre-existing tombstones re-authored,
        # which is what the ruling was issued to fix.
        assert c.mode == :translated,
               "#{name}: expected :translated under checked omission, got #{c.mode}"
      end
    end
  end
end
