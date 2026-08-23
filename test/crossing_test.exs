defmodule Yepochs.CrossingTest do
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Text
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Crossing
  alias Yepochs.Crossing.Receipt
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Span
  alias Yepochs.Test.Updates

  defp span(lc, lk, rc, rk, len) do
    {:ok, s} =
      Span.new(left_client: lc, left_clock: lk, right_client: rc, right_clock: rk, length: len)

    s
  end

  defp bridge(spans) do
    {:ok, d} = Derivation.new(spans)
    {:ok, b} = Bridge.attach(d, "origin-epoch", "derived-epoch", Algorithm.snapshot())
    b
  end

  defp full_bridge, do: bridge([span(100, 0, 500, 0, 8)])

  defp text(%Doc{} = d), do: Text.to_string(d, "t")

  defp apply_to(%Doc{} = dest, <<>>), do: text(dest)

  defp apply_to(%Doc{} = dest, update) do
    {:ok, d} = Encoding.apply_update(dest, update)
    text(d)
  end

  defp opts(extra \\ []) do
    Keyword.merge([from: :left, author: 9000, receipt_ref: "commit-abc"], extra)
  end

  setup_all do
    %{source: Updates.base("abcdefgh", 100), dest: Updates.base("abcdefgh", 500)}
  end

  describe "the Bridge contract — every valid edit crosses, in either direction" do
    test "takes the strict path when the correspondence covers the edit",
         %{source: source, dest: dest} do
      u = Updates.insert_delta(source, 200, 2, "XY")

      assert {:ok, %Crossing{} = c} = Yepochs.cross(full_bridge(), u, source, dest, opts())
      assert c.mode == :translated
      assert c.outcome == :applied
      assert c.from_epoch == "origin-epoch"
      assert c.to_epoch == "derived-epoch"
      assert apply_to(dest, c.update) == "abXYcdefgh"
    end

    test "⭐ RE-AUTHORS instead of failing when the correspondence does not cover the anchor",
         %{source: source, dest: dest} do
      # The anchor for this insert is uncovered, so strict translation cannot
      # prove an exact mapping. §27.4: that MUST select re-authoring, not a
      # "cannot cross" result.
      u = Updates.insert_delta(source, 200, 2, "XY")
      partial = bridge([span(100, 5, 500, 5, 3)])

      assert {:ok, %Crossing{} = c} = Yepochs.cross(partial, u, source, dest, opts())
      assert c.mode == :reauthored
      assert c.outcome == :applied

      assert apply_to(dest, c.update) == "abXYcdefgh",
             "the observable effect must arrive even without an exact translation"
    end

    test "re-authors a DELETE whose target is uncovered", %{source: source, dest: dest} do
      u = Updates.delete_delta(source, 200, 2, 3)
      assert {:ok, c} = Yepochs.cross(bridge([]), u, source, dest, opts())
      assert c.mode == :reauthored
      assert apply_to(dest, c.update) == "abfgh"
    end

    test "ABSORBS an edit whose effect is already true at the destination", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      already = Updates.base("abXYcdefgh", 500)

      assert {:ok, c} = Yepochs.cross(bridge([]), u, source, already, opts())
      assert c.mode == :absorbed
      assert c.outcome == :absorbed
      assert c.update == <<>>
      assert apply_to(already, c.update) == "abXYcdefgh"
    end

    test "crosses RIGHT-to-left as well", %{source: source, dest: dest} do
      u = Updates.insert_delta(dest, 600, 2, "ZZ")

      assert {:ok, c} = Yepochs.cross(full_bridge(), u, dest, source, opts(from: :right))
      assert c.from_epoch == "derived-epoch"
      assert c.to_epoch == "origin-epoch"
      assert apply_to(source, c.update) == "abZZcdefgh"
    end

    test "⛔ never surfaces a strict-path diagnostic as the crossing result",
         %{source: source, dest: dest} do
      # §22: cross/5 MUST NOT return :missing_anchor, :missing_operation_target
      # or :target_identity_collision for an otherwise supported edit.
      strict_only = [:missing_anchor, :missing_operation_target, :target_identity_collision]

      for b <- [bridge([]), bridge([span(100, 5, 500, 5, 3)]), bridge([span(100, 0, 200, 0, 8)])],
          u <- [
            Updates.insert_delta(source, 200, 2, "XY"),
            Updates.delete_delta(source, 200, 1, 2)
          ] do
        case Yepochs.cross(b, u, source, dest, opts()) do
          {:ok, %Crossing{}} -> :ok
          {:error, %Error{code: code}} -> refute code in strict_only
        end
      end
    end

    # Spec r3 §28.2 fixture 18.
    test "re-authors around an identity collision, which strict translation cannot survive",
         %{source: source, dest: dest} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      colliding = bridge([span(100, 0, 200, 0, 8)])

      assert {:ok, c} = Yepochs.cross(colliding, u, source, dest, opts())
      assert c.mode == :reauthored
      assert apply_to(dest, c.update) == "abXYcdefgh"
    end
  end

  describe "the adapter's totality has an edge, and it is reported — §22 :rebase_conflict" do
    test "refuses when the destination no longer holds what the edit replaces", %{source: source} do
      # The edit removes "cde" after the prefix "ab". This destination has "ab"
      # but not "cde" after it, so the positional adapter cannot place the change
      # deterministically. Guessing a position is the one thing it must not do.
      diverged = Updates.base("abZZZfgh", 500)
      u = Updates.delete_delta(source, 200, 2, 3)

      assert {:error, %Error{code: :rebase_conflict, phase: :rebase} = err} =
               Yepochs.cross(bridge([]), u, source, diverged, opts())

      assert err.details.removed == "cde"
    end

    test "the same edit succeeds against a destination that DOES hold it", %{
      source: source,
      dest: dest
    } do
      u = Updates.delete_delta(source, 200, 2, 3)
      assert {:ok, c} = Yepochs.cross(bridge([]), u, source, dest, opts())
      assert apply_to(dest, c.update) == "abfgh"
    end
  end

  describe "every crossing returns a delta and a receipt — invariants 11 and 12" do
    test "a translated crossing returns a receipt naming both endpoints", %{
      source: source,
      dest: dest
    } do
      u = Updates.insert_delta(source, 200, 2, "XY")
      {:ok, c} = Yepochs.cross(full_bridge(), u, source, dest, opts())

      assert %Receipt{ref: "commit-abc", from: :left, to: :right, mode: :translated} =
               c.bridge_delta.receipt
    end

    # Spec r3 §28.2 fixture 20.
    test "an ABSORBED crossing still returns a receipt, though its correspondence is empty",
         %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      already = Updates.base("abXYcdefgh", 500)

      {:ok, c} = Yepochs.cross(bridge([]), u, source, already, opts())
      assert %Receipt{ref: "commit-abc", mode: :absorbed} = c.bridge_delta.receipt
      assert c.bridge_delta.correspondence.spans == []
    end

    test "the delta's spans are oriented to the BRIDGE, not to the crossing direction",
         %{source: source, dest: dest} do
      # Crossing right-to-left, the authored side is the bridge's RIGHT.
      u = Updates.insert_delta(dest, 600, 2, "ZZ")
      {:ok, c} = Yepochs.cross(full_bridge(), u, dest, source, opts(from: :right))

      for s <- c.bridge_delta.correspondence.spans do
        assert s.right_client == 600, "authored ids belong on the bridge's right endpoint here"
      end

      assert %Receipt{from: :right, to: :left} = c.bridge_delta.receipt
    end

    test "the delta extends the bridge, and the result is usable", %{source: source, dest: dest} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      b = full_bridge()
      {:ok, c} = Yepochs.cross(b, u, source, dest, opts())

      assert {:ok, extended} = Bridge.extend(b, c.bridge_delta)
      assert Bridge.right_ref(extended, {200, 0}) == {:ok, {200, 0}}
      assert [%Receipt{ref: "commit-abc"}] = extended.receipts
    end

    test "records the crossing algorithm", %{source: source, dest: dest} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      {:ok, c} = Yepochs.cross(full_bridge(), u, source, dest, opts())
      assert c.algorithm == Algorithm.cross()
    end
  end

  describe "determinism and required options" do
    test "the same inputs produce the same bytes and the same receipt", %{
      source: source,
      dest: dest
    } do
      u = Updates.insert_delta(source, 200, 2, "XY")

      results =
        for _ <- 1..20 do
          {:ok, c} = Yepochs.cross(bridge([]), u, source, dest, opts())
          {c.update, c.mode, c.bridge_delta.receipt}
        end

      assert results |> Enum.uniq() |> length() == 1
    end

    test "requires an explicit direction", %{source: source, dest: dest} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      o = Keyword.delete(opts(), :from)
      assert {:error, %Error{}} = Yepochs.cross(full_bridge(), u, source, dest, o)
    end

    test "requires an opaque receipt reference", %{source: source, dest: dest} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      o = Keyword.delete(opts(), :receipt_ref)
      assert {:error, %Error{}} = Yepochs.cross(full_bridge(), u, source, dest, o)
    end

    test "requires a destination author id, since re-authoring must allocate one",
         %{source: source, dest: dest} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      o = Keyword.delete(opts(), :author)
      assert {:error, %Error{}} = Yepochs.cross(full_bridge(), u, source, dest, o)
    end
  end
end
