defmodule Yepochs.SpanTest do
  use ExUnit.Case, async: true

  alias Yepochs.Error
  alias Yepochs.Span

  # r2 §8.1: left/right are a STABLE ORIENTATION, not a direction of travel.
  # For a fresh snapshot derivation left is the origin (old) document and right
  # is the derived (new) one.
  defp valid(overrides \\ []) do
    Keyword.merge(
      [left_client: 9, left_clock: 21, right_client: 17, right_clock: 4, length: 5],
      overrides
    )
  end

  describe "new/1" do
    test "builds a span pairing left and right coordinates" do
      assert {:ok, %Span{} = s} = Span.new(valid())
      assert s.left_client == 9
      assert s.left_clock == 21
      assert s.right_client == 17
      assert s.right_clock == 4
      assert s.length == 5
    end

    test "accepts clock zero on both sides" do
      assert {:ok, _} = Span.new(valid(left_clock: 0, right_clock: 0))
    end

    test "rejects a zero length, because §6.2 requires a positive length" do
      assert {:error, %Error{code: :invalid_derivation}} = Span.new(valid(length: 0))
    end

    test "rejects a negative length" do
      assert {:error, %Error{code: :invalid_derivation}} = Span.new(valid(length: -1))
    end

    test "rejects a negative clock" do
      assert {:error, %Error{code: :invalid_derivation}} = Span.new(valid(right_clock: -1))
    end

    test "rejects a negative client id" do
      assert {:error, %Error{code: :invalid_derivation}} = Span.new(valid(left_client: -1))
    end

    test "rejects a non-integer coordinate" do
      assert {:error, %Error{code: :invalid_derivation}} = Span.new(valid(right_client: 1.0))
      assert {:error, %Error{code: :invalid_derivation}} = Span.new(valid(left_clock: "3"))
    end

    test "rejects a coordinate above the Yjs safe-integer range" do
      assert {:error, %Error{code: :invalid_derivation}} =
               Span.new(valid(right_client: Bitwise.bsl(1, 53)))
    end

    test "rejects an interval whose end overflows the safe-integer range" do
      max = Bitwise.bsl(1, 53) - 1

      assert {:error, %Error{code: :invalid_derivation}} =
               Span.new(valid(left_clock: max, length: 2))
    end

    test "the error names the offending field rather than only prose" do
      assert {:error, %Error{code: :invalid_derivation} = err} = Span.new(valid(length: 0))
      assert err.phase == :derivation
      assert err.path == [:length]
    end
  end

  describe "interval accessors" do
    test "left_end/1 and right_end/1 are exclusive, per the half-open range in §6.2" do
      {:ok, s} = Span.new(valid())
      assert Span.left_end(s) == 26
      assert Span.right_end(s) == 9
    end
  end

  describe "sort_key/1" do
    test "orders LEFT-first: left client, left clock, right client, right clock" do
      {:ok, s} = Span.new(valid())
      assert Span.sort_key(s) == {9, 21, 17, 4}
    end
  end

  describe "flip/1" do
    test "exchanges the two sides, which is how a span is reoriented" do
      {:ok, s} = Span.new(valid())
      f = Span.flip(s)
      assert f.left_client == 17
      assert f.left_clock == 4
      assert f.right_client == 9
      assert f.right_clock == 21
      assert f.length == 5
    end
  end
end
