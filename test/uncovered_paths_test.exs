defmodule Yepochs.UncoveredPathsTest do
  @moduledoc """
  Paths that `mix test --cover` showed were never executed.

  Coverage is a **differently drawn partition** from both unit tests and mutation
  testing: it does not ask whether a check works, it asks whether a line ever
  ran. Several of these are error and fallback branches — the code that only
  executes when something has already gone wrong, and therefore the code least
  likely to have been exercised and most likely to be wrong when it finally is.
  """
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.ID
  alias Yelixer.Item
  alias Yelixer.Types.Array
  alias Yelixer.Types.Text
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Bridge.Basis
  alias Yepochs.Crossing.Receipt
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Preflight
  alias Yepochs.Rebase
  alias Yepochs.Span
  alias Yepochs.Test.Updates
  alias Yepochs.Update

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

  describe "§15.7 — an ID-valued parent with NO mapping" do
    test "fails with :missing_operation_target, not :missing_anchor" do
      # Never executed before: every ID-parent test supplied a bridge that
      # covered it. §15.7 distinguishes this from a missing anchor, and the
      # distinction is only observable when the mapping is absent.
      source = Updates.base("abcdefgh", 100)
      {:ok, decoded} = Update.decode(Updates.insert_delta(source, 200, 2, "XY"))

      orphan = %Item{
        id: %ID{client: 700, clock: 0},
        origin: nil,
        right_origin: nil,
        content: {:string, "Q"},
        parent: {:id, %ID{client: 100, clock: 3}},
        parent_sub: nil,
        deleted: false,
        length: 1
      }

      tainted = %{decoded | items: decoded.items ++ [orphan]}
      # Covers the anchors but NOT clock 3, which the orphan parents onto.
      partial = bridge("A", "B", [span(100, 0, 500, 0, 3)])

      assert {:error, %Error{code: :missing_operation_target} = err} =
               Preflight.run(tainted, partial, :left, [])

      assert Enum.any?(err.details.failures, &(&1.field == :parent and &1.ref == {100, 3}))
    end
  end

  describe "inverting a COMPOSED bridge, whose basis roles are null" do
    test "flip leaves null origin/derived alone" do
      # Every previous inversion test used a snapshot basis, so the nil branch of
      # Basis.flip/1 never ran.
      ab = bridge("A", "B", [span(10, 0, 20, 0, 5)])
      bc = bridge("B", "C", [span(20, 0, 30, 0, 5)])
      {:ok, ac} = Bridge.compose([ab, bc])
      assert %Basis{kind: :composition, origin: nil, derived: nil} = ac.basis

      assert {:ok, inverted} = Bridge.invert(ac)
      assert %Basis{kind: :composition, origin: nil, derived: nil} = inverted.basis
      assert inverted.left_epoch == "C" and inverted.right_epoch == "A"
      assert Bridge.right_ref(inverted, {30, 2}) == {:ok, {10, 2}}
    end

    test "invert(invert(composed)) round-trips" do
      ab = bridge("A", "B", [span(10, 0, 20, 0, 5)])
      bc = bridge("B", "C", [span(20, 0, 30, 0, 5)])
      {:ok, ac} = Bridge.compose([ab, bc])
      {:ok, i} = Bridge.invert(ac)
      assert {:ok, ^ac} = Bridge.invert(i)
    end
  end

  describe "a named type the edit INTRODUCES — the {:empty, kind} branches" do
    test "a text type that did not exist in `before` is carried across" do
      before = mat(Text.insert(Doc.new(client_id: 100), "t", 0, "ab"))
      edited = mat(Text.insert(before, "fresh", 0, "new"))
      target = mat(Text.insert(Doc.new(client_id: 500), "t", 0, "ab"))

      assert {:ok, r} = Rebase.rebase(before, edited, target, author: 9000)
      {:ok, out} = Encoding.apply_update(target, r.update)
      assert Text.to_string(out, "fresh") == "new"
    end

    test "an array type that did not exist in `before` is carried across" do
      before = mat(Text.insert(Doc.new(client_id: 100), "t", 0, "ab"))
      edited = mat(Array.insert(before, "list", 0, ["x", "y"]))
      target = mat(Text.insert(Doc.new(client_id: 500), "t", 0, "ab"))

      assert {:ok, r} = Rebase.rebase(before, edited, target, author: 9000)
      {:ok, out} = Encoding.apply_update(target, r.update)
      assert Array.to_list(out, "list") == ["x", "y"]
    end

    test "an unchanged array plane reports no change" do
      before = mat(Array.insert(Doc.new(client_id: 100), "list", 0, ["x"]))
      target = mat(Array.insert(Doc.new(client_id: 500), "list", 0, ["x"]))

      assert {:ok, r} = Rebase.rebase(before, before, target, author: 9000)
      assert r.outcome == :absorbed
    end
  end

  describe "malformed wire values — the from_map fallbacks" do
    test "Derivation.from_map refuses a non-map and a map of the wrong shape" do
      for bad <- [nil, "x", 42, %{}, %{"spans" => []}, %{"version" => 1}] do
        assert {:error, %Error{code: :invalid_derivation}} = Derivation.from_map(bad),
               "accepted #{inspect(bad)}"
      end
    end

    test "Bridge.from_map refuses a map missing required keys" do
      for bad <- [nil, %{}, %{"version" => 1}, %{"version" => 1, "left_epoch" => "a"}] do
        assert {:error, %Error{}} = Bridge.from_map(bad), "accepted #{inspect(bad)}"
      end
    end

    test "Algorithm.from_map and Receipt.from_map refuse malformed input" do
      for bad <- [
            nil,
            %{},
            %{"id" => "x"},
            %{"id" => 1, "version" => 1},
            %{"id" => "x", "version" => 0}
          ] do
        assert :error = Algorithm.from_map(bad), "Algorithm accepted #{inspect(bad)}"
      end

      for bad <- [nil, %{}, %{"ref" => "r"}, %{"ref" => 1, "from" => "left"}] do
        assert :error = Receipt.from_map(bad), "Receipt accepted #{inspect(bad)}"
      end
    end

    test "Basis.from_map refuses a malformed basis" do
      for bad <- [nil, %{}, %{"kind" => "snapshot"}] do
        assert :error = Basis.from_map(bad), "accepted #{inspect(bad)}"
      end
    end

    test "Derivation.validate refuses a non-struct and a bad format version" do
      assert {:error, %Error{code: :invalid_derivation}} = Derivation.validate(%{})

      assert {:error, %Error{code: :invalid_derivation} = err} =
               Derivation.validate(%Derivation{format_version: 99, spans: []})

      assert err.path == [:format_version]
    end

    test "Derivation.new refuses a hand-built span carrying an invalid field" do
      # A struct built without Span.new/1 can hold anything; validate/1 re-runs
      # the field rules precisely so that cannot be smuggled in.
      bad = %Span{left_client: 1, left_clock: 0, right_client: 2, right_clock: 0, length: 0}
      assert {:error, %Error{code: :invalid_derivation} = err} = Derivation.new([bad])
      assert [0 | _] = err.path

      assert {:error, %Error{code: :invalid_derivation}} = Derivation.new([:not_a_span])
    end

    test "Update.decode refuses a non-binary" do
      for bad <- [nil, 42, %{}, :atom] do
        assert {:error, %Error{code: :malformed_update}} = Update.decode(bad)
      end
    end

    test "Derivation exposes its format version" do
      assert Derivation.format_version() == 1
    end

    test "Bridge.from_map refuses a non-list receipts field" do
      map = Bridge.to_map(bridge("a", "b", [span(1, 0, 2, 0, 1)]))

      for bad <- ["nope", %{}, 7] do
        assert {:error, %Error{}} = Bridge.from_map(Map.put(map, "receipts", bad)),
               "accepted receipts=#{inspect(bad)}"
      end

      assert {:error, %Error{}} = Bridge.from_map(Map.put(map, "receipts", [%{"ref" => "r"}]))
    end

    test "Translator refuses input that is neither a binary nor a decoded Update" do
      b = bridge("A", "B", [span(100, 0, 500, 0, 8)])

      for bad <- [nil, 42, %{}, :atom] do
        assert {:error, %Error{code: :malformed_update}} = Yepochs.translate(bad, b, :left, [])
      end
    end
  end

  describe "error propagation arms — reached only when an earlier step already failed" do
    test "normalize and invert refuse a derivation that does not validate" do
      bad = %Derivation{format_version: 99, spans: []}

      assert {:error, %Error{code: :invalid_derivation}} = Derivation.normalize(bad)
      assert {:error, %Error{code: :invalid_derivation}} = Derivation.invert(bad)
    end

    test "cross/5 propagates a malformed update rather than re-authoring around it" do
      source = Updates.base("abcdefgh", 100)
      dest = Updates.base("abcdefgh", 500)

      assert {:error, %Error{code: :malformed_update}} =
               Yepochs.cross(bridge("A", "B", []), <<0xFF, 0xFF, 0xFF>>, source, dest,
                 from: :left,
                 author: 1,
                 receipt_ref: "r"
               )
    end

    test "every parent shape decode/2 can produce is one the translator handles" do
      # `rewrite_parent/2` has a catch-all clause for shapes other than
      # {:named,_}, {:id,_} and {:infer,_}. Coverage showed it never runs — and
      # it CANNOT, from decoded input: yelixer emits only those three. Forcing it
      # with a hand-built `parent: nil` makes yelixer's ENCODER raise, which
      # proves the clause is defensive rather than reachable.
      #
      # ⇒ So the guarantee is asserted instead of the branch: across the upstream
      # corpus and locally-authored documents, every decoded parent is a shape
      # the translator understands. If yelixer ever adds a fourth, this fails and
      # the catch-all stops being merely defensive.
      corpus =
        Path.wildcard("test/fixtures/yjs-v1/*/updates.hex")
        |> Enum.flat_map(fn f ->
          f
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Enum.map(&Base.decode16!(&1, case: :lower))
        end)

      local = [
        Updates.full(Updates.base("abcdefgh", 100)),
        Updates.insert_delta(Updates.base("abcdefgh", 100), 200, 2, "XY"),
        Updates.delete_delta(Updates.base("abcdefgh", 100), 200, 2, 3)
      ]

      assert corpus != [], "the corpus must be non-empty or this proves nothing"

      shapes =
        for bytes <- corpus ++ local, {:ok, u} = Update.decode(bytes), item <- u.items do
          case item.parent do
            {:named, _} -> :named
            {:id, _} -> :id
            {:infer, _} -> :infer
            other -> other
          end
        end

      assert shapes != []

      assert Enum.uniq(shapes) -- [:named, :id, :infer] == [],
             "decode produced an unhandled parent shape: #{inspect(Enum.uniq(shapes))}"
    end

    test "items with a non-named parent are skipped when collecting type names" do
      # Rebase derives type names from the store; an item whose parent is an ID
      # rather than a name contributes none.
      before = mat(Text.insert(Doc.new(client_id: 100), "t", 0, "ab"))

      odd = %Item{
        id: %ID{client: 900, clock: 0},
        origin: nil,
        right_origin: nil,
        content: {:string, "Q"},
        parent: {:id, %ID{client: 100, clock: 0}},
        parent_sub: nil,
        deleted: false,
        length: 1
      }

      store = Yelixer.BlockStore.push(before.store, odd)
      with_odd = %{before | store: store}

      assert {:ok, r} = Rebase.rebase(with_odd, with_odd, before, author: 9000)
      assert r.outcome == :absorbed
    end
  end
end
