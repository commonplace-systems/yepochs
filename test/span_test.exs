defmodule Yepochs.SpanTest do
  use ExUnit.Case, async: true

  alias Yepochs.Error
  alias Yepochs.Span

  defp valid(overrides \\ []) do
    Keyword.merge(
      [target_client: 17, target_clock: 4, source_client: 9, source_clock: 21, length: 5],
      overrides
    )
  end

  describe "new/1" do
    test "builds a span from valid target and source coordinates" do
      assert {:ok, %Span{} = span} = Span.new(valid())
      assert span.target_client == 17
      assert span.target_clock == 4
      assert span.source_client == 9
      assert span.source_clock == 21
      assert span.length == 5
    end

    test "accepts clock zero on both sides" do
      assert {:ok, _} = Span.new(valid(target_clock: 0, source_clock: 0))
    end

    test "rejects a zero length, because §6.2 requires a positive length" do
      assert {:error, %Error{code: :invalid_derivation}} = Span.new(valid(length: 0))
    end

    test "rejects a negative length" do
      assert {:error, %Error{code: :invalid_derivation}} = Span.new(valid(length: -1))
    end

    test "rejects a negative clock" do
      assert {:error, %Error{code: :invalid_derivation}} = Span.new(valid(target_clock: -1))
    end

    test "rejects a negative client id" do
      assert {:error, %Error{code: :invalid_derivation}} = Span.new(valid(source_client: -1))
    end

    test "rejects a non-integer coordinate" do
      assert {:error, %Error{code: :invalid_derivation}} = Span.new(valid(target_client: 1.0))
      assert {:error, %Error{code: :invalid_derivation}} = Span.new(valid(source_clock: "3"))
    end

    test "rejects a coordinate above the Yjs safe-integer range" do
      unsafe = Bitwise.bsl(1, 53)
      assert {:error, %Error{code: :invalid_derivation}} = Span.new(valid(target_client: unsafe))
    end

    test "rejects an interval whose end overflows the safe-integer range" do
      max = Bitwise.bsl(1, 53) - 1
      assert {:error, %Error{code: :invalid_derivation}} =
               Span.new(valid(source_clock: max, length: 2))
    end

    test "the error names the offending field rather than only prose" do
      assert {:error, %Error{code: :invalid_derivation} = err} = Span.new(valid(length: 0))
      assert err.phase == :derivation
      assert err.path == [:length]
    end
  end

  describe "interval accessors" do
    test "target_end/1 and source_end/1 are exclusive, per the half-open range in §6.2" do
      {:ok, span} = Span.new(valid())
      assert Span.target_end(span) == 9
      assert Span.source_end(span) == 26
    end
  end

  describe "sort_key/1" do
    test "orders by target client, then target clock, then source client, then source clock" do
      {:ok, span} = Span.new(valid())
      assert Span.sort_key(span) == {17, 4, 9, 21}
    end
  end
end
