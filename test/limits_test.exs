defmodule Yepochs.LimitsTest do
  use ExUnit.Case, async: true

  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Limits
  alias Yepochs.Preflight
  alias Yepochs.Span
  alias Yepochs.Test.Updates
  alias Yepochs.Translator
  alias Yepochs.Update

  defp span(lc, lk, rc, rk, len) do
    {:ok, s} =
      Span.new(left_client: lc, left_clock: lk, right_client: rc, right_clock: rk, length: len)

    s
  end

  defp bridge(spans) do
    {:ok, d} = Derivation.new(spans)
    {:ok, b} = Bridge.attach(d, "o", "d", Algorithm.snapshot())
    b
  end

  setup_all do
    %{source: Updates.base("abcdefgh", 100)}
  end

  describe "defaults" do
    test "every limit §23 names has a default" do
      l = Limits.new([])

      for key <- [
            :max_update_bytes,
            :max_structs,
            :max_spans,
            :max_delete_intervals,
            :max_depth,
            :max_output_bytes
          ] do
        assert is_integer(Map.fetch!(l, key)), "missing default for #{key}"
      end
    end

    test "ordinary work is nowhere near the defaults", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      assert {:ok, _} = Update.decode(u, Limits.new([]))
    end

    test "callers may override any single limit without losing the others" do
      l = Limits.new(max_structs: 3)
      assert l.max_structs == 3
      assert l.max_update_bytes == Limits.new([]).max_update_bytes
    end
  end

  describe "decoding limits — a failure returns no partial result" do
    test "rejects an update larger than the byte limit", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")

      assert {:error, %Error{code: :limit_exceeded} = err} =
               Update.decode(u, Limits.new(max_update_bytes: 3))

      assert err.details.limit == :max_update_bytes
      assert err.details.actual > 3
    end

    test "rejects an update with more structs than allowed" do
      big = Updates.full(Updates.base("abcdefgh", 100))
      assert {:error, %Error{code: :limit_exceeded} = err} = Update.decode(big, Limits.new(max_structs: 0))
      assert err.details.limit == :max_structs
    end

    test "rejects an update with too many delete intervals", %{source: source} do
      u = Updates.delete_delta(source, 200, 2, 3)

      assert {:error, %Error{code: :limit_exceeded} = err} =
               Update.decode(u, Limits.new(max_delete_intervals: 0))

      assert err.details.limit == :max_delete_intervals
    end

    test "an update at exactly the limit is accepted", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      assert {:ok, _} = Update.decode(u, Limits.new(max_update_bytes: byte_size(u)))
      assert {:error, _} = Update.decode(u, Limits.new(max_update_bytes: byte_size(u) - 1))
    end
  end

  describe "bridge span limit" do
    test "preflight rejects a bridge with too many spans", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      # Non-contiguous on purpose: attach/4 normalizes, and contiguous spans
      # coalesce into one, which would make the limit unreachable.
      b = bridge([span(100, 0, 500, 0, 4), span(100, 10, 500, 10, 4)])
      assert length(b.correspondence.spans) == 2

      assert {:error, %Error{code: :limit_exceeded} = err} =
               Preflight.run(u, b, :left, limits: Limits.new(max_spans: 1))

      assert err.details.limit == :max_spans
    end

    test "accepts a bridge within the span limit", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      b = bridge([span(100, 0, 500, 0, 8)])
      assert {:ok, _} = Preflight.run(u, b, :left, limits: Limits.new(max_spans: 1))
    end
  end

  describe "output limit" do
    test "translation refuses to emit an update over the output limit", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      b = bridge([span(100, 0, 500, 0, 8)])

      assert {:error, %Error{code: :limit_exceeded} = err} =
               Translator.translate(u, b, :left, limits: Limits.new(max_output_bytes: 2))

      assert err.details.limit == :max_output_bytes
    end

    test "emits normally when the output fits", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      b = bridge([span(100, 0, 500, 0, 8)])
      assert {:ok, _} = Translator.translate(u, b, :left, limits: Limits.new(max_output_bytes: 10_000))
    end
  end

  describe "untrusted input — §23 prohibitions" do
    test "wire strings never become atoms" do
      # NOT via :erlang.system_info(:atom_count) -- that is a GLOBAL counter, so
      # any concurrently running async test makes it race. Asserting that the
      # specific string did not become an atom is both race-free and a sharper
      # statement of what §23 forbids.
      exotic = "yepochs-wire-string-#{System.unique_integer([:positive])}"

      map = Bridge.to_map(bridge([span(1, 0, 2, 0, 1)]))

      Bridge.from_map(put_in(map["basis"]["kind"], exotic))
      Bridge.from_map(put_in(map["basis"]["producer"]["id"], exotic))
      Bridge.from_map(put_in(map["left_epoch"], exotic))

      assert_raise ArgumentError, fn -> String.to_existing_atom(exotic) end
    end

    test "malformed input yields a typed error rather than raising" do
      for bytes <- [<<>>, <<0xFF>>, <<0xFF, 0xFF, 0xFF, 0xFF>>, :crypto.strong_rand_bytes(64)] do
        assert {:error, %Error{}} = Update.decode(bytes)
      end
    end
  end
end
