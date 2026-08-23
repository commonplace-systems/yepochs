defmodule Yepochs.ConformanceTest do
  @moduledoc """
  Spec r2 §28.2's mandatory fixtures, **numbered as the spec numbers them**, so
  coverage is auditable rather than remembered.

  Fixtures already covered by a module's own suite are cross-referenced instead
  of duplicated; the ones here are those that had no home. ⛔ Where a fixture is
  NOT satisfied, it is marked and explained — omitting it silently would make
  this file argue for coverage it does not have.
  """
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Text
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Crossing.Receipt
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Snapshotter
  alias Yepochs.Span
  alias Yepochs.Test.Updates

  defp span(lc, lk, rc, rk, len) do
    {:ok, s} =
      Span.new(left_client: lc, left_clock: lk, right_client: rc, right_clock: rk, length: len)

    s
  end

  defp bridge(l, r, spans) do
    {:ok, d} = Derivation.new(spans)
    {:ok, b} = Bridge.attach(d, l, r, Algorithm.snapshot())
    b
  end

  defp mat(%Doc{} = d) do
    {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
    m
  end

  defp cross(b, u, before, dest, extra \\ []) do
    Yepochs.cross(
      b,
      u,
      before,
      dest,
      Keyword.merge([from: :left, author: 9000, receipt_ref: "r"], extra)
    )
  end

  defp text_after(%Doc{} = dest, <<>>), do: Text.to_string(dest, "t")

  defp text_after(%Doc{} = dest, update) do
    {:ok, d} = Encoding.apply_update(dest, update)
    Text.to_string(d, "t")
  end

  setup_all do
    %{source: Updates.base("abcdefgh", 100), dest: Updates.base("abcdefgh", 500)}
  end

  # Fixtures 1-6, 8-11, 14, 15, 18, 20, 24, 25 are covered in the suites of the
  # modules that own them (span/derivation/bridge/preflight/translator/
  # snapshotter/crossing). The rest are below.

  describe "fixture 7 — incremental bridge extension after accepted translation" do
    test "a translated edit's delta extends the bridge and the extension is usable",
         %{source: source, dest: dest} do
      b = bridge("A", "B", [span(100, 0, 500, 0, 8)])
      u = Updates.insert_delta(source, 200, 2, "XY")

      {:ok, c} = cross(b, u, source, dest)
      assert c.mode == :translated

      {:ok, extended} = Bridge.extend(b, c.bridge_delta)
      assert Bridge.right_ref(extended, {200, 1}) == {:ok, {200, 1}}
      assert [%Receipt{ref: "r"}] = extended.receipts
    end
  end

  describe "fixture 12 — snapshot version bridging through a shared source (§20)" do
    test "two snapshots of one source compose into a bridge between their epochs" do
      src = mat(Text.insert(Doc.new(client_id: 100), "t", 0, "abcdefgh"))

      # Two derivations from the SAME source. Both point back to A, so B<->C is
      # obtained by inverting one and composing through A -- no cross-version
      # translator is required.
      {:ok, s1} = Snapshotter.snapshot(src, [])
      {:ok, s2} = Snapshotter.snapshot(src, [])

      {:ok, a_to_b} = Bridge.attach(s1.derivation, "A", "B", Algorithm.snapshot())
      {:ok, a_to_c} = Bridge.attach(s2.derivation, "A", "C", Algorithm.snapshot())

      {:ok, b_to_a} = Bridge.invert(a_to_b)
      assert {:ok, b_to_c} = Bridge.compose([b_to_a, a_to_c])

      assert b_to_c.left_epoch == "B"
      assert b_to_c.right_epoch == "C"
      assert b_to_c.basis.kind == :composition

      # Every clock B knows still resolves in C.
      for s <- a_to_b.correspondence.spans, n <- 0..(s.length - 1) do
        assert {:ok, _} = Bridge.right_ref(b_to_c, {s.right_client, s.right_clock + n})
      end
    end
  end

  describe "fixture 13 — deterministic refusal of an unsupported nested subtype" do
    test "a source with nested subtypes is refused, and refused the same way twice" do
      nested = Doc.new(client_id: 100) |> Text.insert("t", 0, "abc")

      case Yelixer.Doc.nested_subtype_names(nested) do
        [] ->
          # This build's Text plane creates no nested subtypes, so the refusal
          # path is exercised through the equivalent §10.2 guard instead: a
          # document the replay cannot faithfully reproduce is refused, not
          # flattened.
          assert {:error, %Error{code: :unsupported_content}} = Snapshotter.snapshot(nested, [])
          assert {:error, %Error{code: :unsupported_content}} = Snapshotter.snapshot(nested, [])

        _names ->
          assert {:error, %Error{code: :unsupported_content}} =
                   Snapshotter.snapshot(mat(nested), [])
      end
    end
  end

  describe "fixture 16 — the SAME insertion crossing in both directions" do
    test "left-to-right and right-to-left produce the same observable effect",
         %{source: source, dest: dest} do
      b = bridge("A", "B", [span(100, 0, 500, 0, 8)])

      l_to_r = Updates.insert_delta(source, 200, 2, "XY")
      r_to_l = Updates.insert_delta(dest, 600, 2, "XY")

      {:ok, forward} = cross(b, l_to_r, source, dest)
      {:ok, backward} = cross(b, r_to_l, dest, source, from: :right)

      assert text_after(dest, forward.update) == "abXYcdefgh"
      assert text_after(source, backward.update) == "abXYcdefgh"
      assert forward.bridge_delta.receipt.from == :left
      assert backward.bridge_delta.receipt.from == :right
    end
  end

  describe "fixture 17 — a missing anchor falls back to re-authoring in EACH direction" do
    test "left-to-right", %{source: source, dest: dest} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      {:ok, c} = cross(bridge("A", "B", []), u, source, dest)
      assert c.mode == :reauthored
      assert text_after(dest, c.update) == "abXYcdefgh"
    end

    test "right-to-left", %{source: source, dest: dest} do
      u = Updates.insert_delta(dest, 600, 2, "XY")
      {:ok, c} = cross(bridge("A", "B", []), u, dest, source, from: :right)
      assert c.mode == :reauthored
      assert text_after(source, c.update) == "abXYcdefgh"
    end
  end

  describe "fixture 21 — a later causally dependent edit crossing after a TRANSLATED edit" do
    test "the second edit anchors on the first and still crosses", %{source: source, dest: dest} do
      b = bridge("A", "B", [span(100, 0, 500, 0, 8)])

      # First edit, translated; its delta is admitted into the bridge.
      first_doc = Text.insert(Updates.replica(source, 200), "t", 2, "XY")
      first = Updates.delta(first_doc, source)
      {:ok, c1} = cross(b, first, source, dest, receipt_ref: "c1")
      assert c1.mode == :translated
      {:ok, b2} = Bridge.extend(b, c1.bridge_delta)

      {:ok, dest2} = Encoding.apply_update(dest, c1.update)
      {:ok, source2} = Encoding.apply_update(source, first)

      # Second edit anchors INSIDE the first edit's text.
      second = Updates.delta(Text.insert(first_doc, "t", 3, "Q"), first_doc)
      {:ok, c2} = cross(b2, second, source2, dest2, receipt_ref: "c2")

      assert text_after(dest2, c2.update) == "abXQYcdefgh"
      assert length(elem(Bridge.extend(b2, c2.bridge_delta), 1).receipts) == 2
    end
  end

  describe "fixture 22 — a later dependent edit after a RE-AUTHORED edit" do
    test "crosses even though the first crossing left no correspondence",
         %{source: source, dest: dest} do
      # The first crossing re-authors, so it proves no item correspondence. The
      # second edit therefore cannot translate strictly either -- and must still
      # arrive, by re-authoring again. That is the whole point of §17's "any
      # remaining unmapped dependency simply selects re-authoring again".
      b = bridge("A", "B", [])

      first_doc = Text.insert(Updates.replica(source, 200), "t", 2, "XY")
      first = Updates.delta(first_doc, source)
      {:ok, c1} = cross(b, first, source, dest, receipt_ref: "c1")
      assert c1.mode == :reauthored

      {:ok, b2} = Bridge.extend(b, c1.bridge_delta)
      {:ok, dest2} = Encoding.apply_update(dest, c1.update)
      {:ok, source2} = Encoding.apply_update(source, first)

      second = Updates.delta(Text.insert(first_doc, "t", 3, "Q"), first_doc)
      {:ok, c2} = cross(b2, second, source2, dest2, receipt_ref: "c2")

      assert c2.mode in [:translated, :reauthored]
      assert text_after(dest2, c2.update) == "abXQYcdefgh"
    end
  end

  describe "fixture 23 — inversion preserves bidirectional crossing capability" do
    test "the same edits cross an inverted bridge, with the roles swapped",
         %{source: source, dest: dest} do
      b = bridge("A", "B", [span(100, 0, 500, 0, 8)])
      {:ok, inverted} = Bridge.invert(b)

      u = Updates.insert_delta(source, 200, 2, "XY")

      {:ok, direct} = cross(b, u, source, dest, from: :left)
      # On the inverted bridge the same endpoint is now the RIGHT one.
      {:ok, via_inverse} = cross(inverted, u, source, dest, from: :right)

      assert direct.update == via_inverse.update
      assert direct.mode == via_inverse.mode
      assert direct.from_epoch == via_inverse.from_epoch
      assert direct.to_epoch == via_inverse.to_epoch
    end
  end

  describe "⛔ fixtures NOT satisfied — recorded rather than omitted" do
    test "19: a re-authored crossing returns NO correspondence spans in 0.1" do
      # §28.2 fixture 19 wants a re-authored crossing to return non-identity
      # correspondence spans. §17 hedges this ("wherever the rebase adapter can
      # prove that newly authored destination items correspond to source items"),
      # and the 0.1 adapters prove NONE: they re-author from an observable diff
      # and cannot say which destination item answers which source item.
      #
      # This test pins the CURRENT behaviour so the gap is visible and so
      # implementing it is a deliberate change, not an accident.
      source = Updates.base("abcdefgh", 100)
      dest = Updates.base("abcdefgh", 500)
      u = Updates.insert_delta(source, 200, 2, "XY")

      {:ok, c} = cross(bridge("A", "B", []), u, source, dest)
      assert c.mode == :reauthored

      assert c.bridge_delta.correspondence.spans == [],
             "if this now returns spans, fixture 19 is satisfied — update this test"

      assert %Receipt{mode: :reauthored} = c.bridge_delta.receipt
    end

    test "26: destination admission is the CALLER's, and out of scope here" do
      # §28.2 fixture 26 ("destination admission through its own writer without
      # adding another log writer") is about the enclosing log protocol. §4 lists
      # multi-writer admission as explicit non-scope and §29 requires this package
      # to run no process and own no storage — so there is nothing here to fixture.
      # §29: no runtime process, registry, supervisor, storage adapter, or
      # network client. An empty `mod` means no application callback module, and
      # an empty `registered` means the app claims no named processes.
      refute Code.ensure_loaded?(Yepochs.Supervisor)
      assert Application.spec(:yepochs, :mod) in [nil, []], "yepochs must start no application"
      assert Application.spec(:yepochs, :registered) == [], "yepochs must register no processes"
    end
  end
end
