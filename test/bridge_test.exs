defmodule Yepochs.BridgeTest do
  use ExUnit.Case, async: true

  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Bridge.Basis
  alias Yepochs.Bridge.Delta
  alias Yepochs.Crossing.Receipt
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Span

  defp span(lc, lk, rc, rk, len) do
    {:ok, s} =
      Span.new(left_client: lc, left_clock: lk, right_client: rc, right_clock: rk, length: len)

    s
  end

  defp deriv(spans) do
    {:ok, d} = Derivation.new(spans)
    d
  end

  defp bridge(origin, derived, spans) do
    {:ok, b} = Bridge.attach(deriv(spans), origin, derived, Algorithm.snapshot())
    b
  end

  defp receipt(ref, opts \\ []) do
    %Receipt{
      ref: ref,
      from: Keyword.get(opts, :from, :left),
      to: Keyword.get(opts, :to, :right),
      mode: Keyword.get(opts, :mode, :translated),
      outcome: Keyword.get(opts, :outcome, :applied),
      algorithm: Algorithm.cross()
    }
  end

  defp delta(spans, %Receipt{} = r), do: %Delta{correspondence: deriv(spans), receipt: r}

  describe "attach/4" do
    test "assigns the ORIGIN to left and the DERIVED Yepoch to right" do
      assert {:ok, %Bridge{} = b} =
               Bridge.attach(
                 deriv([span(9, 21, 17, 4, 5)]),
                 "origin-epoch",
                 "derived-epoch",
                 Algorithm.snapshot()
               )

      assert b.left_epoch == "origin-epoch"
      assert b.right_epoch == "derived-epoch"
      assert b.format_version == 1
    end

    test "records the directed snapshot fact in basis, on opposite sides" do
      b = bridge("a", "b", [])
      assert %Basis{kind: :snapshot, origin: :left, derived: :right} = b.basis
      assert b.basis.producer == Algorithm.snapshot()
    end

    test "starts with no receipts" do
      assert bridge("a", "b", []).receipts == []
    end

    test "normalizes the correspondence while attaching, and changes no span content" do
      b = bridge("a", "b", [span(2, 105, 1, 5, 3), span(2, 100, 1, 0, 5)])
      assert [%Span{left_clock: 100, right_clock: 0, length: 8}] = b.correspondence.spans
    end

    test "rejects an empty epoch reference" do
      assert {:error, %Error{code: :invalid_epoch_ref}} =
               Bridge.attach(deriv([]), "", "b", Algorithm.snapshot())
    end

    test "rejects an epoch reference longer than 1024 UTF-8 bytes" do
      assert {:error, %Error{code: :invalid_epoch_ref}} =
               Bridge.attach(deriv([]), "a", String.duplicate("x", 1025), Algorithm.snapshot())

      assert {:ok, _} =
               Bridge.attach(deriv([]), "a", String.duplicate("x", 1024), Algorithm.snapshot())
    end

    test "measures the 1024 limit in BYTES, not characters" do
      assert {:error, %Error{code: :invalid_epoch_ref}} =
               Bridge.attach(deriv([]), "a", String.duplicate("あ", 512), Algorithm.snapshot())
    end

    test "rejects an epoch reference that is not valid UTF-8" do
      # §6.3 requires a canonical UTF-8 string. Invalid bytes are refused rather
      # than stored and compared byte-for-byte as if they were text.
      assert {:error, %Error{code: :invalid_epoch_ref}} =
               Bridge.attach(deriv([]), "a", <<0xFF, 0xFE, 0xFD>>, Algorithm.snapshot())
    end

    test "rejects a non-binary epoch reference" do
      for bad <- [nil, 42, :atom, ["a"]] do
        assert {:error, %Error{code: :invalid_epoch_ref}} =
                 Bridge.attach(deriv([]), "a", bad, Algorithm.snapshot()),
               "expected #{inspect(bad)} to be refused as an epoch reference"
      end
    end

    test "rejects equal endpoints" do
      assert {:error, %Error{code: :invalid_epoch_ref}} =
               Bridge.attach(deriv([]), "same", "same", Algorithm.snapshot())
    end
  end

  describe "lookup" do
    setup do
      %{b: bridge("origin", "derived", [span(9, 21, 17, 4, 5)])}
    end

    test "right_ref/2 takes a LEFT coordinate and returns its right counterpart", %{b: b} do
      assert Bridge.right_ref(b, {9, 21}) == {:ok, {17, 4}}
    end

    test "left_ref/2 takes a RIGHT coordinate and returns its left counterpart", %{b: b} do
      assert Bridge.left_ref(b, {17, 4}) == {:ok, {9, 21}}
    end

    # Spec r3 §28.2 fixture 1.
    test "resolves a reference into the MIDDLE of a multi-clock item", %{b: b} do
      assert Bridge.right_ref(b, {9, 23}) == {:ok, {17, 6}}
      assert Bridge.left_ref(b, {17, 6}) == {:ok, {9, 23}}
    end

    test "resolves the last clock of a span but not the exclusive end", %{b: b} do
      assert Bridge.right_ref(b, {9, 25}) == {:ok, {17, 8}}
      assert Bridge.right_ref(b, {9, 26}) == :unmapped
    end

    test "returns :unmapped rather than falling back to the same numeric coordinate", %{b: b} do
      assert Bridge.right_ref(b, {9, 999}) == :unmapped
      assert Bridge.right_ref(b, {999, 21}) == :unmapped
      # A right-side coordinate is not a left-side one, even though both exist.
      assert Bridge.right_ref(b, {17, 4}) == :unmapped
    end
  end

  describe "invert/1" do
    test "exchanges endpoint references and every span coordinate" do
      b = bridge("a", "b", [span(9, 21, 17, 4, 5)])
      assert {:ok, i} = Bridge.invert(b)
      assert i.left_epoch == "b"
      assert i.right_epoch == "a"
      assert Bridge.right_ref(i, {17, 4}) == {:ok, {9, 21}}
    end

    test "exchanges the basis ROLES, so provenance survives reorientation" do
      b = bridge("a", "b", [span(9, 21, 17, 4, 5)])
      {:ok, i} = Bridge.invert(b)
      assert %Basis{kind: :snapshot, origin: :right, derived: :left} = i.basis
    end

    test "exchanges from/to in every receipt" do
      b = bridge("a", "b", [span(1, 0, 2, 0, 4)])
      {:ok, b} = Bridge.extend(b, delta([], receipt("r1", from: :left, to: :right)))
      {:ok, i} = Bridge.invert(b)
      assert [%Receipt{ref: "r1", from: :right, to: :left}] = i.receipts
    end

    test "invert(invert(b)) == normalize(b) — it is presentation, not a new relationship" do
      b = bridge("a", "b", [span(1, 50, 9, 50, 2), span(1, 0, 2, 0, 2), span(1, 2, 2, 2, 3)])
      {:ok, i} = Bridge.invert(b)
      {:ok, ii} = Bridge.invert(i)
      assert ii == b
    end
  end

  describe "compose/1" do
    test "rejects an empty list" do
      assert {:error, %Error{}} = Bridge.compose([])
    end

    test "a single bridge composes to itself" do
      b = bridge("a", "b", [span(9, 21, 17, 4, 5)])
      assert {:ok, ^b} = Bridge.compose([b])
    end

    test "composes A<->B<->C into A<->C through the shared endpoint" do
      ab = bridge("A", "B", [span(10, 0, 20, 0, 5)])
      bc = bridge("B", "C", [span(20, 0, 30, 0, 5)])
      assert {:ok, ac} = Bridge.compose([ab, bc])
      assert ac.left_epoch == "A"
      assert ac.right_epoch == "C"
      assert Bridge.right_ref(ac, {10, 2}) == {:ok, {30, 2}}
      assert Bridge.left_ref(ac, {30, 2}) == {:ok, {10, 2}}
    end

    test "lookup across a composed bridge equals successive lookup across its inputs" do
      ab = bridge("A", "B", [span(10, 0, 20, 100, 8)])
      bc = bridge("B", "C", [span(20, 103, 30, 7, 4)])
      {:ok, ac} = Bridge.compose([ab, bc])

      for clock <- 3..6 do
        {:ok, b_ref} = Bridge.right_ref(ab, {10, clock})
        {:ok, c_ref} = Bridge.right_ref(bc, b_ref)
        assert Bridge.right_ref(ac, {10, clock}) == {:ok, c_ref}
      end
    end

    # Spec r3 §28.2 fixture 11.
    test "splits at intermediate boundaries and keeps only fully-mapped coordinates" do
      ab = bridge("A", "B", [span(10, 0, 20, 0, 10)])
      bc = bridge("B", "C", [span(20, 3, 30, 0, 4)])
      {:ok, ac} = Bridge.compose([ab, bc])

      assert Bridge.right_ref(ac, {10, 2}) == :unmapped
      assert Bridge.right_ref(ac, {10, 3}) == {:ok, {30, 0}}
      assert Bridge.right_ref(ac, {10, 6}) == {:ok, {30, 3}}
      assert Bridge.right_ref(ac, {10, 7}) == :unmapped
    end

    test "re-offsets INTO the second bridge when the clip cuts its left start" do
      ab = bridge("A", "B", [span(10, 0, 20, 5, 10)])
      bc = bridge("B", "C", [span(20, 0, 30, 0, 10)])
      {:ok, ac} = Bridge.compose([ab, bc])
      assert Bridge.right_ref(ac, {10, 0}) == {:ok, {30, 5}}
      assert Bridge.right_ref(ac, {10, 4}) == {:ok, {30, 9}}
      assert Bridge.right_ref(ac, {10, 5}) == :unmapped
    end

    test "re-offsets INTO the first bridge when the clip cuts its right start" do
      ab = bridge("A", "B", [span(10, 0, 20, 0, 10)])
      bc = bridge("B", "C", [span(20, 4, 30, 0, 6)])
      {:ok, ac} = Bridge.compose([ab, bc])
      assert Bridge.right_ref(ac, {10, 4}) == {:ok, {30, 0}}
      assert Bridge.right_ref(ac, {10, 3}) == :unmapped
    end

    test "never invents coverage that neither input had" do
      ab = bridge("A", "B", [span(10, 0, 20, 0, 3)])
      bc = bridge("B", "C", [span(20, 50, 30, 0, 3)])
      {:ok, ac} = Bridge.compose([ab, bc])
      assert ac.correspondence.spans == []
    end

    test "rejects a disconnected path" do
      ab = bridge("A", "B", [span(10, 0, 20, 0, 5)])
      cd = bridge("C", "D", [span(30, 0, 40, 0, 5)])
      assert {:error, %Error{code: :bridge_endpoint_mismatch}} = Bridge.compose([ab, cd])
    end

    test "rejects bridges supplied in the wrong order" do
      ab = bridge("A", "B", [span(10, 0, 20, 0, 5)])
      bc = bridge("B", "C", [span(20, 0, 30, 0, 5)])
      assert {:error, %Error{code: :bridge_endpoint_mismatch}} = Bridge.compose([bc, ab])
    end

    test "uses a COMPOSITION basis with null roles, claiming no direct derivation" do
      ab = bridge("A", "B", [span(10, 0, 20, 0, 5)])
      bc = bridge("B", "C", [span(20, 0, 30, 0, 5)])
      {:ok, ac} = Bridge.compose([ab, bc])
      assert %Basis{kind: :composition, origin: nil, derived: nil} = ac.basis
      assert ac.basis.producer == Algorithm.compose()
    end

    test "leaves edge-specific receipts on their original bridges" do
      ab = bridge("A", "B", [span(10, 0, 20, 0, 5)])
      {:ok, ab} = Bridge.extend(ab, delta([], receipt("edge-receipt")))
      bc = bridge("B", "C", [span(20, 0, 30, 0, 5)])
      {:ok, ac} = Bridge.compose([ab, bc])

      assert ac.receipts == []
      assert [%Receipt{ref: "edge-receipt"}] = ab.receipts
    end

    test "is associative after normalization" do
      ab = bridge("A", "B", [span(10, 0, 20, 0, 10)])
      bc = bridge("B", "C", [span(20, 2, 30, 5, 6)])
      cd = bridge("C", "D", [span(30, 7, 40, 0, 3)])

      {:ok, li} = Bridge.compose([ab, bc])
      {:ok, left} = Bridge.compose([li, cd])
      {:ok, ri} = Bridge.compose([bc, cd])
      {:ok, right} = Bridge.compose([ab, ri])

      assert left.correspondence == right.correspondence
      assert left.left_epoch == right.left_epoch and left.right_epoch == right.right_epoch
    end

    # Spec r3 §28.2 fixture 10.
    test "composes a three-bridge path" do
      ab = bridge("A", "B", [span(10, 0, 20, 0, 10)])
      bc = bridge("B", "C", [span(20, 0, 30, 0, 10)])
      cd = bridge("C", "D", [span(30, 0, 40, 0, 10)])
      assert {:ok, ad} = Bridge.compose([ab, bc, cd])
      assert ad.left_epoch == "A" and ad.right_epoch == "D"
      assert Bridge.right_ref(ad, {10, 4}) == {:ok, {40, 4}}
    end
  end

  describe "extend/2" do
    setup do
      %{b: bridge("A", "B", [span(10, 0, 20, 0, 5)])}
    end

    test "preserves the bridge endpoints", %{b: b} do
      {:ok, e} = Bridge.extend(b, delta([span(11, 0, 21, 0, 3)], receipt("r1")))
      assert e.left_epoch == "A" and e.right_epoch == "B"
    end

    test "adds the new correspondence and retains the earlier one unchanged", %{b: b} do
      {:ok, e} = Bridge.extend(b, delta([span(11, 0, 21, 0, 3)], receipt("r1")))
      assert Bridge.right_ref(e, {11, 1}) == {:ok, {21, 1}}
      assert Bridge.right_ref(e, {10, 1}) == {:ok, {20, 1}}
    end

    test "records the receipt", %{b: b} do
      {:ok, e} = Bridge.extend(b, delta([], receipt("r1")))
      assert [%Receipt{ref: "r1", mode: :translated}] = e.receipts
    end

    test "an ABSORBED edit still records its receipt though its correspondence is empty", %{b: b} do
      {:ok, e} =
        Bridge.extend(b, delta([], receipt("r-abs", mode: :absorbed, outcome: :absorbed)))

      assert [%Receipt{ref: "r-abs", outcome: :absorbed}] = e.receipts
      assert e.correspondence == b.correspondence
    end

    test "a delta may originate from EITHER endpoint", %{b: b} do
      {:ok, e} = Bridge.extend(b, delta([], receipt("r-rl", from: :right, to: :left)))
      assert [%Receipt{from: :right, to: :left}] = e.receipts
    end

    # Spec r3 §28.2 fixture 8.
    test "accepts an exact duplicate mapping idempotently", %{b: b} do
      {:ok, e} = Bridge.extend(b, delta([span(10, 0, 20, 0, 5)], receipt("r1")))
      assert e.correspondence == b.correspondence
    end

    # Spec r3 §28.2 fixture 24.
    test "accepts an exact duplicate RECEIPT idempotently", %{b: b} do
      d = delta([span(11, 0, 21, 0, 3)], receipt("r1"))
      {:ok, once} = Bridge.extend(b, d)
      {:ok, twice} = Bridge.extend(once, d)
      assert once.correspondence == twice.correspondence
      assert length(twice.receipts) == 1
    end

    # Spec r3 §28.2 fixture 25.
    test "REJECTS reuse of one receipt reference for a different crossing result", %{b: b} do
      {:ok, e} = Bridge.extend(b, delta([], receipt("r1", mode: :translated)))

      assert {:error, %Error{code: :receipt_conflict} = err} =
               Bridge.extend(e, delta([], receipt("r1", mode: :reauthored)))

      assert err.details.ref == "r1"
    end

    # Spec r3 §28.2 fixture 9.
    test "rejects an overlap that would give the LEFT side two meanings", %{b: b} do
      assert {:error, %Error{code: :invalid_derivation} = err} =
               Bridge.extend(b, delta([span(10, 2, 99, 99, 2)], receipt("r1")))

      assert err.phase == :bridge and err.path == [:extension]
    end

    test "rejects an overlap that would give the RIGHT side two meanings", %{b: b} do
      assert {:error, %Error{code: :invalid_derivation} = err} =
               Bridge.extend(b, delta([span(99, 99, 20, 2, 2)], receipt("r1")))

      assert err.phase == :bridge and err.path == [:extension]
    end
  end

  describe "to_map/1 and from_map/1" do
    test "matches the wire shape in spec r2 §8.6" do
      b = bridge("origin-epoch-reference", "derived-epoch-reference", [span(9, 21, 17, 4, 5)])

      assert Bridge.to_map(b) == %{
               "version" => 1,
               "left_epoch" => "origin-epoch-reference",
               "right_epoch" => "derived-epoch-reference",
               "basis" => %{
                 "kind" => "snapshot",
                 "origin" => "left",
                 "derived" => "right",
                 "producer" => %{"id" => "yepochs.snapshot", "version" => 3}
               },
               "correspondence" => [
                 %{
                   "left_client" => 9,
                   "left_clock" => 21,
                   "right_client" => 17,
                   "right_clock" => 4,
                   "length" => 5
                 }
               ],
               "receipts" => []
             }
    end

    test "round-trips a bridge carrying receipts" do
      b = bridge("a", "b", [span(9, 21, 17, 4, 5), span(1, 0, 2, 0, 3)])
      {:ok, b} = Bridge.extend(b, delta([], receipt("r1", mode: :reauthored)))
      assert {:ok, ^b} = Bridge.from_map(Bridge.to_map(b))
    end

    test "round-trips a composed bridge, whose basis has null roles" do
      ab = bridge("A", "B", [span(10, 0, 20, 0, 5)])
      bc = bridge("B", "C", [span(20, 0, 30, 0, 5)])
      {:ok, ac} = Bridge.compose([ab, bc])
      assert {:ok, ^ac} = Bridge.from_map(Bridge.to_map(ac))
    end

    test "rejects a snapshot basis whose roles are not opposite sides" do
      map = Bridge.to_map(bridge("a", "b", [span(1, 0, 2, 0, 1)]))
      bad = put_in(map["basis"]["derived"], "left")
      assert {:error, %Error{}} = Bridge.from_map(bad)
    end

    test "does not create atoms from wire strings" do
      # Asserting the specific string never became an atom, rather than counting
      # atoms globally -- the global counter races with every other async test.
      exotic = "bridge-wire-string-#{System.unique_integer([:positive])}"
      map = Bridge.to_map(bridge("a", "b", [span(1, 0, 2, 0, 1)]))

      Bridge.from_map(put_in(map["basis"]["kind"], exotic))
      Bridge.from_map(put_in(map["basis"]["producer"]["id"], exotic))

      Bridge.from_map(
        put_in(map["receipts"], [
          %{
            "ref" => "r",
            "from" => exotic,
            "to" => "right",
            "mode" => "translated",
            "outcome" => "applied",
            "algorithm" => %{"id" => "yepochs.cross", "version" => 1}
          }
        ])
      )

      assert_raise ArgumentError, fn -> String.to_existing_atom(exotic) end
    end
  end
end
