defmodule Yepochs.CheckedOmissionTest do
  @moduledoc """
  Ruling 3 — checked omission of historical delete ranges.

  `Encoding.encode_diff/2` carries a document's **cumulative** delete set, so an
  edit authored after any deletion repeats coordinates the snapshot derivation
  never mapped (§10.5). Left alone that poisons every later strict translation.

  ⛔ **The omission is CHECKED, not assumed.** A range may be dropped only when
  `yepochs` can prove it was already dead before this edit, that the bridge is
  complete over the source's live content, and that the destination holds no
  live item needing the deletion. Everything else fails closed.
  """
  use ExUnit.Case, async: true

  alias Yelixer.BlockStore
  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Text
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Preflight
  alias Yepochs.Snapshotter
  alias Yepochs.Span

  defp mat(%Doc{} = d) do
    {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
    m
  end

  defp span(lc, lk, rc, rk, len) do
    {:ok, s} =
      Span.new(left_client: lc, left_clock: lk, right_client: rc, right_clock: rk, length: len)

    s
  end

  # A source that has ALREADY had a deletion, plus its snapshot destination.
  defp scarred do
    base = mat(Text.insert(Doc.new(client_id: 100), "t", 0, "abcdefgh"))
    source = mat(Text.delete(base, "t", 2, 3))
    {:ok, s} = Snapshotter.snapshot(source, [])
    {:ok, destination} = Encoding.apply_update(Doc.new(client_id: 500), s.update)
    {:ok, bridge} = Bridge.attach(s.derivation, "origin", "derived", Algorithm.snapshot())
    %{source: source, destination: destination, bridge: bridge}
  end

  defp delta(edited, %Doc{} = from),
    do: Encoding.encode_diff(edited, BlockStore.state_vector(from.store))

  defp cross(ctx, update, extra \\ []) do
    Yepochs.cross(
      ctx.bridge,
      update,
      ctx.source,
      ctx.destination,
      Keyword.merge([from: :left, author: 9000, receipt_ref: "r"], extra)
    )
  end

  defp text(%Doc{} = d, <<>>), do: Text.to_string(d, "t")

  defp text(%Doc{} = d, u) do
    {:ok, out} = Encoding.apply_update(d, u)
    Text.to_string(out, "t")
  end

  describe "1 — an insertion after an old deletion crosses STRICTLY" do
    test "the historical tombstones no longer force re-authoring" do
      ctx = scarred()
      assert Text.to_string(ctx.source, "t") == "abfgh"

      {:ok, c} = cross(ctx, delta(Text.insert(ctx.source, "t", 0, "Z"), ctx.source))

      assert c.mode == :translated,
             "an edit whose only uncovered delete coordinates are checked historical " <>
               "ranges must keep the strict path, got #{c.mode}"

      assert text(ctx.destination, c.update) == "Zabfgh"
    end

    test "the omission is reported in preflight output, not hidden in the encoder" do
      ctx = scarred()
      update = delta(Text.insert(ctx.source, "t", 0, "Z"), ctx.source)

      {:ok, plan} =
        Preflight.run(update, ctx.bridge, :left,
          source_before: ctx.source,
          destination: ctx.destination
        )

      assert plan.omitted != [], "a checked omission must be visible in the plan"
      assert Enum.all?(plan.omitted, fn {c, _k, l} -> c == 100 and l > 0 end)
    end
  end

  describe "2 — a NEWLY introduced uncovered deletion re-authors" do
    test "a novel delete of content the bridge does not cover is never omitted" do
      base = mat(Text.insert(Doc.new(client_id: 100), "t", 0, "abcdefgh"))
      {:ok, s} = Snapshotter.snapshot(base, [])
      {:ok, destination} = Encoding.apply_update(Doc.new(client_id: 500), s.update)

      # A bridge that covers only part of the live content.
      {:ok, d} = Derivation.new([span(100, 0, 500, 0, 2)])
      {:ok, partial} = Bridge.attach(d, "origin", "derived", Algorithm.snapshot())

      ctx = %{source: base, destination: destination, bridge: partial}
      update = delta(Text.delete(base, "t", 4, 2), base)

      {:ok, c} = cross(ctx, update)

      assert c.mode == :reauthored,
             "a NOVEL uncovered deletion must not be omitted, got #{c.mode}"

      assert text(destination, c.update) == "abcdgh"
    end
  end

  describe "3 — a mixed delete interval is split" do
    test "covered, checked-historical and novel subranges are handled independently" do
      ctx = scarred()

      # Deletes across the seam: live content the bridge covers, in one update
      # that also repeats the historical tombstones.
      update = delta(Text.delete(ctx.source, "t", 0, 2), ctx.source)
      {:ok, c} = cross(ctx, update)

      assert c.mode == :translated
      assert text(ctx.destination, c.update) == "fgh"
    end
  end

  describe "4 — fails closed without the exact source-before state" do
    test "translate/4, which has no endpoint states, still refuses" do
      ctx = scarred()
      update = delta(Text.insert(ctx.source, "t", 0, "Z"), ctx.source)

      assert {:error, %Error{code: :missing_operation_target}} =
               Yepochs.translate(update, ctx.bridge, :left, []),
             "the low-level API must stay conservative when it cannot prove omission"
    end

    test "preflight without source_before refuses even when destination is given" do
      ctx = scarred()
      update = delta(Text.insert(ctx.source, "t", 0, "Z"), ctx.source)

      assert {:error, %Error{code: :missing_operation_target}} =
               Preflight.run(update, ctx.bridge, :left, destination: ctx.destination)
    end

    test "a source_before that does not carry the deletion refuses" do
      ctx = scarred()
      update = delta(Text.insert(ctx.source, "t", 0, "Z"), ctx.source)
      unscarred = mat(Text.insert(Doc.new(client_id: 100), "t", 0, "abcdefgh"))

      assert {:error, %Error{code: :missing_operation_target}} =
               Preflight.run(update, ctx.bridge, :left,
                 source_before: unscarred,
                 destination: ctx.destination
               ),
             "if the range was not already dead, omitting it would discard a real deletion"
    end
  end

  describe "5 — fails closed when bridge completeness cannot be established" do
    test "a bridge that does not cover all live source content refuses to omit" do
      ctx = scarred()
      update = delta(Text.insert(ctx.source, "t", 0, "Z"), ctx.source)

      # Covers only some of the live content, so the destination's relationship
      # to the tombstoned range cannot be concluded.
      {:ok, d} = Derivation.new([span(100, 0, 500, 0, 1)])
      {:ok, incomplete} = Bridge.attach(d, "origin", "derived", Algorithm.snapshot())

      assert {:error, %Error{code: :missing_operation_target}} =
               Preflight.run(update, incomplete, :left,
                 source_before: ctx.source,
                 destination: ctx.destination
               )
    end

    test "and cross/5 then re-authors rather than failing the crossing" do
      ctx = scarred()
      {:ok, d} = Derivation.new([span(100, 0, 500, 0, 1)])
      {:ok, incomplete} = Bridge.attach(d, "origin", "derived", Algorithm.snapshot())

      update = delta(Text.insert(ctx.source, "t", 0, "Z"), ctx.source)
      {:ok, c} = cross(%{ctx | bridge: incomplete}, update)

      assert c.mode == :reauthored
      assert text(ctx.destination, c.update) == "Zabfgh"
    end
  end

  describe "6 — the upstream Yjs delete vectors stop re-authoring" do
    @fixtures Path.join(__DIR__, "fixtures/yjs-v1")

    test "003-005 cross as :translated once historical ranges are checked" do
      for name <- [
            "003-concurrent-overlapping-deletes",
            "004-concurrent-adjacent-deletes",
            "005-delete-then-concurrent-insert"
          ] do
        updates =
          Path.join([@fixtures, name, "updates.hex"])
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Enum.map(&Base.decode16!(&1, case: :lower))

        source =
          Enum.reduce(updates, Doc.new(client_id: 1), fn u, d ->
            {:ok, d} = Encoding.apply_update(d, u)
            d
          end)

        {:ok, s} = Snapshotter.snapshot(source, [])
        {:ok, destination} = Encoding.apply_update(Doc.new(client_id: 500), s.update)
        {:ok, bridge} = Bridge.attach(s.derivation, "origin", "derived", Algorithm.snapshot())

        update = delta(Text.insert(source, "t", 0, "Z"), source)

        {:ok, c} =
          Yepochs.cross(bridge, update, source, destination,
            from: :left,
            author: 9000,
            receipt_ref: name
          )

        assert c.mode == :translated,
               "#{name}: must no longer re-author solely for repeating pre-existing " <>
                 "tombstones, got #{c.mode}"

        assert text(destination, c.update) == "Z" <> Text.to_string(source, "t")
      end
    end
  end
end
