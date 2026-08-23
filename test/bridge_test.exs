defmodule Yepochs.BridgeTest do
  use ExUnit.Case, async: true

  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Span

  defp span(tc, tk, sc, sk, len) do
    {:ok, s} =
      Span.new(target_client: tc, target_clock: tk, source_client: sc, source_clock: sk, length: len)

    s
  end

  defp deriv(spans) do
    {:ok, d} = Derivation.new(spans)
    d
  end

  defp snapshotter, do: %Algorithm{id: "yepochs.snapshot", version: 2}

  defp bridge(src, tgt, spans) do
    {:ok, b} = Bridge.attach(deriv(spans), src, tgt, snapshotter())
    b
  end

  describe "attach/4" do
    test "builds a bridge from a derivation and two epoch references" do
      assert {:ok, %Bridge{} = b} =
               Bridge.attach(deriv([span(17, 4, 9, 21, 5)]), "epoch-a", "epoch-b", snapshotter())

      assert b.source_epoch == "epoch-a"
      assert b.target_epoch == "epoch-b"
      assert b.producer == snapshotter()
      assert b.format_version == 1
    end

    test "normalizes the derivation while attaching, and changes no span content" do
      spans = [span(1, 5, 2, 105, 3), span(1, 0, 2, 100, 5)]
      {:ok, b} = Bridge.attach(deriv(spans), "a", "b", snapshotter())
      assert [%Span{target_clock: 0, source_clock: 100, length: 8}] = b.derivation.spans
    end

    test "rejects an empty epoch reference" do
      assert {:error, %Error{code: :invalid_epoch_ref}} =
               Bridge.attach(deriv([]), "", "b", snapshotter())
    end

    test "rejects an epoch reference longer than 1024 UTF-8 bytes" do
      long = String.duplicate("x", 1025)

      assert {:error, %Error{code: :invalid_epoch_ref}} =
               Bridge.attach(deriv([]), "a", long, snapshotter())

      assert {:ok, _} = Bridge.attach(deriv([]), "a", String.duplicate("x", 1024), snapshotter())
    end

    test "measures the 1024 limit in BYTES, not characters" do
      # 512 three-byte characters is 1536 bytes.
      assert {:error, %Error{code: :invalid_epoch_ref}} =
               Bridge.attach(deriv([]), "a", String.duplicate("あ", 512), snapshotter())
    end

    test "rejects equal endpoints" do
      assert {:error, %Error{code: :invalid_epoch_ref}} =
               Bridge.attach(deriv([]), "same", "same", snapshotter())
    end
  end

  describe "lookup" do
    # Stored provenance direction is target -> source.
    setup do
      %{b: bridge("src-epoch", "tgt-epoch", [span(17, 4, 9, 21, 5)])}
    end

    test "source_ref/2 walks the stored direction, target -> source", %{b: b} do
      assert Bridge.source_ref(b, {17, 4}) == {:ok, {9, 21}}
    end

    test "target_ref/2 walks the translation direction, source -> target", %{b: b} do
      assert Bridge.target_ref(b, {9, 21}) == {:ok, {17, 4}}
    end

    test "resolves a reference into the MIDDLE of a multi-clock item", %{b: b} do
      assert Bridge.source_ref(b, {17, 6}) == {:ok, {9, 23}}
      assert Bridge.target_ref(b, {9, 23}) == {:ok, {17, 6}}
    end

    test "resolves the last clock of a span but not the exclusive end", %{b: b} do
      assert Bridge.source_ref(b, {17, 8}) == {:ok, {9, 25}}
      assert Bridge.source_ref(b, {17, 9}) == :unmapped
    end

    test "returns :unmapped rather than falling back to the same numeric coordinate", %{b: b} do
      assert Bridge.source_ref(b, {17, 999}) == :unmapped
      assert Bridge.source_ref(b, {999, 4}) == :unmapped
      assert Bridge.target_ref(b, {17, 4}) == :unmapped
    end
  end

  describe "invert/1" do
    test "swaps the endpoint references and every span coordinate" do
      b = bridge("a", "b", [span(17, 4, 9, 21, 5)])
      assert {:ok, i} = Bridge.invert(b)
      assert i.source_epoch == "b"
      assert i.target_epoch == "a"
      assert Bridge.source_ref(i, {9, 21}) == {:ok, {17, 4}}
    end

    test "invert(invert(b)) == normalize(b)" do
      b = bridge("a", "b", [span(9, 50, 1, 50, 2), span(2, 0, 1, 0, 2), span(2, 2, 1, 2, 3)])
      {:ok, i} = Bridge.invert(b)
      {:ok, ii} = Bridge.invert(i)
      assert ii == b
    end
  end

  describe "compose/1" do
    test "rejects an empty list" do
      assert {:error, %Error{}} = Bridge.compose([])
    end

    test "a single bridge composes to itself, with its own producer preserved" do
      b = bridge("a", "b", [span(17, 4, 9, 21, 5)])
      assert {:ok, ^b} = Bridge.compose([b])
    end

    test "composes A->B->C into A->C, chaining provenance C -> B -> A" do
      ab = bridge("A", "B", [span(20, 0, 10, 0, 5)])
      bc = bridge("B", "C", [span(30, 0, 20, 0, 5)])
      assert {:ok, ac} = Bridge.compose([ab, bc])
      assert ac.source_epoch == "A"
      assert ac.target_epoch == "C"
      assert Bridge.target_ref(ac, {10, 2}) == {:ok, {30, 2}}
      assert Bridge.source_ref(ac, {30, 2}) == {:ok, {10, 2}}
    end

    test "lookup across a composed bridge equals successive lookup across its inputs" do
      ab = bridge("A", "B", [span(20, 100, 10, 0, 8)])
      bc = bridge("B", "C", [span(30, 7, 20, 103, 4)])
      {:ok, ac} = Bridge.compose([ab, bc])

      for source_clock <- 3..6 do
        {:ok, b_ref} = Bridge.target_ref(ab, {10, source_clock})
        {:ok, c_ref} = Bridge.target_ref(bc, b_ref)
        assert Bridge.target_ref(ac, {10, source_clock}) == {:ok, c_ref}
      end
    end

    test "splits at intermediate boundaries and keeps only fully-mapped coordinates" do
      ab = bridge("A", "B", [span(20, 0, 10, 0, 10)])
      # Only B clocks 3..6 continue on to C.
      bc = bridge("B", "C", [span(30, 0, 20, 3, 4)])
      {:ok, ac} = Bridge.compose([ab, bc])

      assert Bridge.target_ref(ac, {10, 2}) == :unmapped
      assert Bridge.target_ref(ac, {10, 3}) == {:ok, {30, 0}}
      assert Bridge.target_ref(ac, {10, 6}) == {:ok, {30, 3}}
      assert Bridge.target_ref(ac, {10, 7}) == :unmapped
    end

    test "re-offsets INTO the second bridge when the clip cuts its source start" do
      # ab covers B clocks 5..15; bc covers B clocks 0..10. The shared range
      # starts at 5, which is 5 clocks into bc's source interval -- so the
      # composed target clock must advance by 5, not stay at bc's start.
      ab = bridge("A", "B", [span(20, 5, 10, 0, 10)])
      bc = bridge("B", "C", [span(30, 0, 20, 0, 10)])
      {:ok, ac} = Bridge.compose([ab, bc])

      assert Bridge.target_ref(ac, {10, 0}) == {:ok, {30, 5}}
      assert Bridge.target_ref(ac, {10, 4}) == {:ok, {30, 9}}
      assert Bridge.target_ref(ac, {10, 5}) == :unmapped
    end

    test "re-offsets INTO the first bridge when the clip cuts its target start" do
      ab = bridge("A", "B", [span(20, 0, 10, 0, 10)])
      bc = bridge("B", "C", [span(30, 0, 20, 4, 6)])
      {:ok, ac} = Bridge.compose([ab, bc])

      assert Bridge.target_ref(ac, {10, 4}) == {:ok, {30, 0}}
      assert Bridge.target_ref(ac, {10, 3}) == :unmapped
    end

    test "composition never invents coverage that neither input had" do
      ab = bridge("A", "B", [span(20, 0, 10, 0, 3)])
      bc = bridge("B", "C", [span(30, 0, 20, 50, 3)])
      {:ok, ac} = Bridge.compose([ab, bc])
      assert ac.derivation.spans == []
    end

    test "rejects a disconnected path" do
      ab = bridge("A", "B", [span(20, 0, 10, 0, 5)])
      cd = bridge("C", "D", [span(40, 0, 30, 0, 5)])
      assert {:error, %Error{code: :bridge_endpoint_mismatch}} = Bridge.compose([ab, cd])
    end

    test "rejects bridges supplied in the wrong order" do
      ab = bridge("A", "B", [span(20, 0, 10, 0, 5)])
      bc = bridge("B", "C", [span(30, 0, 20, 0, 5)])
      assert {:error, %Error{code: :bridge_endpoint_mismatch}} = Bridge.compose([bc, ab])
    end

    test "uses an explicit composition producer rather than pretending a snapshotter made it" do
      ab = bridge("A", "B", [span(20, 0, 10, 0, 5)])
      bc = bridge("B", "C", [span(30, 0, 20, 0, 5)])
      {:ok, ac} = Bridge.compose([ab, bc])
      assert ac.producer == %Algorithm{id: "yepochs.compose", version: 1}
    end

    test "is associative after normalization" do
      ab = bridge("A", "B", [span(20, 0, 10, 0, 10)])
      bc = bridge("B", "C", [span(30, 5, 20, 2, 6)])
      cd = bridge("C", "D", [span(40, 0, 30, 7, 3)])

      {:ok, left_inner} = Bridge.compose([ab, bc])
      {:ok, left} = Bridge.compose([left_inner, cd])
      {:ok, right_inner} = Bridge.compose([bc, cd])
      {:ok, right} = Bridge.compose([ab, right_inner])

      assert left.derivation == right.derivation
      assert left.source_epoch == right.source_epoch
      assert left.target_epoch == right.target_epoch
    end

    test "composes a three-bridge path" do
      ab = bridge("A", "B", [span(20, 0, 10, 0, 10)])
      bc = bridge("B", "C", [span(30, 0, 20, 0, 10)])
      cd = bridge("C", "D", [span(40, 0, 30, 0, 10)])
      assert {:ok, ad} = Bridge.compose([ab, bc, cd])
      assert ad.source_epoch == "A"
      assert ad.target_epoch == "D"
      assert Bridge.target_ref(ad, {10, 4}) == {:ok, {40, 4}}
    end
  end

  describe "extend/2" do
    setup do
      %{b: bridge("A", "B", [span(20, 0, 10, 0, 5)])}
    end

    test "preserves the bridge endpoints", %{b: b} do
      {:ok, e} = Bridge.extend(b, deriv([span(21, 0, 11, 0, 3)]))
      assert e.source_epoch == "A"
      assert e.target_epoch == "B"
    end

    test "adds the new mapping", %{b: b} do
      {:ok, e} = Bridge.extend(b, deriv([span(21, 0, 11, 0, 3)]))
      assert Bridge.target_ref(e, {11, 1}) == {:ok, {21, 1}}
      assert Bridge.target_ref(e, {10, 1}) == {:ok, {20, 1}}
    end

    test "accepts an exact duplicate mapping idempotently", %{b: b} do
      {:ok, e} = Bridge.extend(b, deriv([span(20, 0, 10, 0, 5)]))
      assert e.derivation == b.derivation
    end

    test "duplicate extension applied twice is still idempotent", %{b: b} do
      add = deriv([span(21, 0, 11, 0, 3)])
      {:ok, once} = Bridge.extend(b, add)
      {:ok, twice} = Bridge.extend(once, add)
      assert once.derivation == twice.derivation
    end

    test "rejects an overlap that would give the target side two meanings", %{b: b} do
      assert {:error, %Error{code: :invalid_derivation} = err} =
               Bridge.extend(b, deriv([span(20, 2, 99, 99, 2)]))

      # Named as an extension conflict, not merely as a malformed derivation:
      # the caller needs to know its admission record was the thing rejected.
      assert err.phase == :bridge
      assert err.path == [:extension]
    end

    test "rejects an overlap that would give the source side two meanings", %{b: b} do
      assert {:error, %Error{code: :invalid_derivation} = err} =
               Bridge.extend(b, deriv([span(99, 99, 10, 2, 2)]))

      assert err.phase == :bridge
      assert err.path == [:extension]
    end
  end

  describe "to_map/1 and from_map/1" do
    test "matches the wire shape in spec §8.5" do
      b = bridge("source-epoch-reference", "target-epoch-reference", [span(17, 4, 9, 21, 5)])

      assert Bridge.to_map(b) == %{
               "version" => 1,
               "source_epoch" => "source-epoch-reference",
               "target_epoch" => "target-epoch-reference",
               "producer" => %{"id" => "yepochs.snapshot", "version" => 2},
               "spans" => [
                 %{
                   "target_client" => 17,
                   "target_clock" => 4,
                   "source_client" => 9,
                   "source_clock" => 21,
                   "length" => 5
                 }
               ]
             }
    end

    test "round-trips without semantic change" do
      b = bridge("a", "b", [span(17, 4, 9, 21, 5), span(2, 0, 1, 0, 3)])
      assert {:ok, back} = Bridge.from_map(Bridge.to_map(b))
      assert back == b
    end

    test "from_map does not create atoms from wire strings" do
      before = :erlang.system_info(:atom_count)
      map = Bridge.to_map(bridge("a", "b", [span(1, 0, 2, 0, 1)]))
      {:ok, _} = Bridge.from_map(put_in(map["producer"]["id"], "yepochs.definitely-not-an-atom-yet"))
      assert :erlang.system_info(:atom_count) == before
    end
  end
end
