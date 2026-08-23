defmodule Yepochs.DerivationTest do
  use ExUnit.Case, async: true

  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Span

  defp span(lc, lk, rc, rk, len) do
    {:ok, s} =
      Span.new(left_client: lc, left_clock: lk, right_client: rc, right_clock: rk, length: len)

    s
  end

  describe "new/1" do
    test "accepts an empty span list" do
      assert {:ok, %Derivation{format_version: 1, spans: []}} = Derivation.new([])
    end

    test "accepts a single well-formed span" do
      assert {:ok, %Derivation{spans: [_]}} = Derivation.new([span(9, 21, 17, 4, 5)])
    end

    test "rejects overlapping LEFT intervals, because invariant 4 requires a partial bijection" do
      spans = [span(2, 0, 1, 0, 5), span(2, 3, 1, 100, 5)]
      assert {:error, %Error{code: :invalid_derivation, phase: :derivation}} = Derivation.new(spans)
    end

    test "rejects overlapping RIGHT intervals" do
      spans = [span(2, 0, 1, 0, 5), span(2, 100, 1, 3, 5)]
      assert {:error, %Error{code: :invalid_derivation}} = Derivation.new(spans)
    end

    test "allows equal clocks on different clients" do
      assert {:ok, _} = Derivation.new([span(2, 0, 1, 0, 5), span(4, 0, 3, 0, 5)])
    end

    test "allows exactly adjacent, non-overlapping intervals" do
      assert {:ok, _} = Derivation.new([span(2, 0, 1, 0, 5), span(2, 5, 1, 5, 5)])
    end
  end

  describe "normalize/1" do
    test "sorts spans LEFT-first into canonical order" do
      spans = [span(1, 50, 9, 50, 2), span(1, 0, 2, 0, 2), span(1, 10, 9, 10, 2)]
      {:ok, d} = Derivation.new(spans)
      {:ok, n} = Derivation.normalize(d)
      assert Enum.map(n.spans, &Span.sort_key/1) == [{1, 0, 2, 0}, {1, 10, 9, 10}, {1, 50, 9, 50}]
    end

    test "coalesces spans contiguous on BOTH sides with matching clients" do
      spans = [span(2, 100, 1, 0, 5), span(2, 105, 1, 5, 3)]
      {:ok, d} = Derivation.new(spans)
      {:ok, n} = Derivation.normalize(d)
      assert [%Span{left_clock: 100, right_clock: 0, length: 8}] = n.spans
    end

    test "does NOT coalesce when only one side is contiguous" do
      spans = [span(2, 100, 1, 0, 5), span(2, 105, 1, 900, 3)]
      {:ok, d} = Derivation.new(spans)
      {:ok, n} = Derivation.normalize(d)
      assert length(n.spans) == 2
    end

    test "does NOT coalesce across different clients on one side" do
      spans = [span(2, 100, 1, 0, 5), span(2, 105, 3, 5, 3)]
      {:ok, d} = Derivation.new(spans)
      {:ok, n} = Derivation.normalize(d)
      assert length(n.spans) == 2
    end

    test "does not fill gaps or infer a mapping" do
      spans = [span(2, 0, 1, 0, 2), span(2, 10, 1, 10, 2)]
      {:ok, d} = Derivation.new(spans)
      {:ok, n} = Derivation.normalize(d)
      assert Enum.map(n.spans, & &1.length) == [2, 2]
    end

    test "is idempotent" do
      spans = [span(1, 50, 9, 50, 2), span(1, 0, 2, 0, 2), span(1, 2, 2, 2, 3)]
      {:ok, d} = Derivation.new(spans)
      {:ok, once} = Derivation.normalize(d)
      {:ok, twice} = Derivation.normalize(once)
      assert once == twice
    end

    test "the same logical derivation normalizes to byte-equivalent to_map output" do
      {:ok, da} = Derivation.new([span(2, 100, 1, 0, 5), span(2, 105, 1, 5, 3)])
      {:ok, db} = Derivation.new([span(2, 105, 1, 5, 3), span(2, 100, 1, 0, 5)])
      {:ok, na} = Derivation.normalize(da)
      {:ok, nb} = Derivation.normalize(db)
      assert Derivation.to_map(na) == Derivation.to_map(nb)
    end
  end

  describe "invert/1" do
    test "exchanges left and right coordinates in every span" do
      {:ok, d} = Derivation.new([span(9, 21, 17, 4, 5)])
      {:ok, i} = Derivation.invert(d)
      assert [%Span{left_client: 17, left_clock: 4, right_client: 9, right_clock: 21, length: 5}] =
               i.spans
    end

    test "invert(invert(d)) == normalize(d)" do
      spans = [span(1, 50, 9, 50, 2), span(1, 0, 2, 0, 2), span(1, 2, 2, 2, 3)]
      {:ok, d} = Derivation.new(spans)
      {:ok, n} = Derivation.normalize(d)
      {:ok, i} = Derivation.invert(d)
      {:ok, ii} = Derivation.invert(i)
      assert ii == n
    end
  end

  describe "to_map/1 and from_map/1" do
    test "the wire form uses string keys and left/right coordinates" do
      {:ok, d} = Derivation.new([span(9, 21, 17, 4, 5)])

      assert Derivation.to_map(d) == %{
               "version" => 1,
               "spans" => [
                 %{
                   "left_client" => 9,
                   "left_clock" => 21,
                   "right_client" => 17,
                   "right_clock" => 4,
                   "length" => 5
                 }
               ]
             }
    end

    test "round-trips without semantic change" do
      {:ok, d} = Derivation.new([span(9, 21, 17, 4, 5), span(1, 0, 2, 0, 3)])
      {:ok, n} = Derivation.normalize(d)
      assert {:ok, ^n} = Derivation.from_map(Derivation.to_map(n))
    end

    test "from_map rejects an unsupported format version" do
      assert {:error, %Error{code: :invalid_derivation}} =
               Derivation.from_map(%{"version" => 99, "spans" => []})
    end

    test "from_map rejects a malformed span rather than creating atoms from wire data" do
      assert {:error, %Error{code: :invalid_derivation}} =
               Derivation.from_map(%{"version" => 1, "spans" => [%{"left_client" => 1}]})
    end
  end
end
