defmodule Yepochs.DerivationTest do
  use ExUnit.Case, async: true

  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Span

  defp span(tc, tk, sc, sk, len) do
    {:ok, s} =
      Span.new(
        target_client: tc,
        target_clock: tk,
        source_client: sc,
        source_clock: sk,
        length: len
      )

    s
  end

  describe "new/1" do
    test "accepts an empty span list" do
      assert {:ok, %Derivation{format_version: 1, spans: []}} = Derivation.new([])
    end

    test "accepts a single well-formed span" do
      assert {:ok, %Derivation{spans: [_]}} = Derivation.new([span(17, 4, 9, 21, 5)])
    end

    test "rejects overlapping target intervals, because invariant 4 requires a partial bijection" do
      spans = [span(1, 0, 2, 0, 5), span(1, 3, 2, 100, 5)]
      assert {:error, %Error{code: :invalid_derivation, phase: :derivation}} = Derivation.new(spans)
    end

    test "rejects overlapping source intervals" do
      spans = [span(1, 0, 2, 0, 5), span(1, 100, 2, 3, 5)]
      assert {:error, %Error{code: :invalid_derivation}} = Derivation.new(spans)
    end

    test "allows equal clocks on different clients" do
      spans = [span(1, 0, 2, 0, 5), span(3, 0, 4, 0, 5)]
      assert {:ok, _} = Derivation.new(spans)
    end

    test "allows exactly adjacent, non-overlapping intervals" do
      spans = [span(1, 0, 2, 0, 5), span(1, 5, 2, 5, 5)]
      assert {:ok, _} = Derivation.new(spans)
    end
  end

  describe "normalize/1" do
    test "sorts spans into canonical order" do
      spans = [span(9, 50, 1, 50, 2), span(2, 0, 1, 0, 2), span(9, 10, 1, 10, 2)]
      {:ok, d} = Derivation.new(spans)
      {:ok, n} = Derivation.normalize(d)
      assert Enum.map(n.spans, &Span.sort_key/1) == [{2, 0, 1, 0}, {9, 10, 1, 10}, {9, 50, 1, 50}]
    end

    test "coalesces spans contiguous on BOTH sides with matching clients" do
      spans = [span(1, 0, 2, 100, 5), span(1, 5, 2, 105, 3)]
      {:ok, d} = Derivation.new(spans)
      {:ok, n} = Derivation.normalize(d)
      assert [%Span{target_clock: 0, source_clock: 100, length: 8}] = n.spans
    end

    test "does NOT coalesce when only the target side is contiguous" do
      spans = [span(1, 0, 2, 100, 5), span(1, 5, 2, 900, 3)]
      {:ok, d} = Derivation.new(spans)
      {:ok, n} = Derivation.normalize(d)
      assert length(n.spans) == 2
    end

    test "does NOT coalesce across different source clients" do
      spans = [span(1, 0, 2, 100, 5), span(1, 5, 3, 105, 3)]
      {:ok, d} = Derivation.new(spans)
      {:ok, n} = Derivation.normalize(d)
      assert length(n.spans) == 2
    end

    test "does not fill gaps or infer a mapping" do
      spans = [span(1, 0, 2, 0, 2), span(1, 10, 2, 10, 2)]
      {:ok, d} = Derivation.new(spans)
      {:ok, n} = Derivation.normalize(d)
      assert Enum.map(n.spans, & &1.length) == [2, 2]
    end

    test "is idempotent" do
      spans = [span(9, 50, 1, 50, 2), span(2, 0, 1, 0, 2), span(2, 2, 1, 2, 3)]
      {:ok, d} = Derivation.new(spans)
      {:ok, once} = Derivation.normalize(d)
      {:ok, twice} = Derivation.normalize(once)
      assert once == twice
    end

    test "the same logical derivation normalizes to byte-equivalent to_map output" do
      a = [span(1, 0, 2, 100, 5), span(1, 5, 2, 105, 3)]
      b = [span(1, 5, 2, 105, 3), span(1, 0, 2, 100, 5)]
      {:ok, da} = Derivation.new(a)
      {:ok, db} = Derivation.new(b)
      {:ok, na} = Derivation.normalize(da)
      {:ok, nb} = Derivation.normalize(db)
      assert Derivation.to_map(na) == Derivation.to_map(nb)
    end
  end

  describe "invert/1" do
    test "swaps target and source coordinates in every span" do
      {:ok, d} = Derivation.new([span(17, 4, 9, 21, 5)])
      {:ok, i} = Derivation.invert(d)
      assert [%Span{target_client: 9, target_clock: 21, source_client: 17, source_clock: 4, length: 5}] = i.spans
    end

    test "invert(invert(d)) == normalize(d)" do
      spans = [span(9, 50, 1, 50, 2), span(2, 0, 1, 0, 2), span(2, 2, 1, 2, 3)]
      {:ok, d} = Derivation.new(spans)
      {:ok, n} = Derivation.normalize(d)
      {:ok, i} = Derivation.invert(d)
      {:ok, ii} = Derivation.invert(i)
      assert ii == n
    end
  end

  describe "to_map/1 and from_map/1" do
    test "the wire form uses string keys and a sorted span list" do
      {:ok, d} = Derivation.new([span(17, 4, 9, 21, 5)])
      map = Derivation.to_map(d)

      assert map == %{
               "version" => 1,
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
      {:ok, d} = Derivation.new([span(17, 4, 9, 21, 5), span(2, 0, 1, 0, 3)])
      {:ok, n} = Derivation.normalize(d)
      assert {:ok, back} = Derivation.from_map(Derivation.to_map(n))
      assert back == n
    end

    test "from_map rejects an unsupported format version" do
      assert {:error, %Error{code: :invalid_derivation}} =
               Derivation.from_map(%{"version" => 99, "spans" => []})
    end

    test "from_map rejects a malformed span rather than creating atoms from wire data" do
      assert {:error, %Error{code: :invalid_derivation}} =
               Derivation.from_map(%{"version" => 1, "spans" => [%{"target_client" => 1}]})
    end
  end
end
