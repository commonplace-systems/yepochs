defmodule Yepochs.VersioningTest do
  @moduledoc """
  Spec r2 §21 — a durable caller MUST be able to select an algorithm version
  explicitly, and the library MUST NOT silently substitute a newer one.
  """
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Text
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
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
    {:ok, b} = Bridge.attach(d, "A", "B", Algorithm.snapshot())
    b
  end

  defp mat(%Doc{} = d) do
    {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
    m
  end

  setup_all do
    %{
      source: Updates.base("abcdefgh", 100),
      dest: Updates.base("abcdefgh", 500),
      doc: mat(Text.insert(Doc.new(client_id: 100), "t", 0, "abcdefgh"))
    }
  end

  describe "supported/0 — the version surface a durable caller reads" do
    test "every algorithm this build implements is listed with its version" do
      by_id = Map.new(Algorithm.supported(), &{&1.id, &1.version})

      assert by_id["yepochs.snapshot"] == 3
      assert by_id["yepochs.translate"] == 1
      assert by_id["yepochs.cross"] == 1
      assert by_id["yepochs.rebase"] == 1
      assert by_id["yepochs.compose"] == 1
      assert by_id["yepochs.extend"] == 1
    end

    test "supports?/1 answers for an exact id and version" do
      assert Algorithm.supports?(%Algorithm{id: "yepochs.snapshot", version: 3})
      refute Algorithm.supports?(%Algorithm{id: "yepochs.snapshot", version: 4})
      refute Algorithm.supports?(%Algorithm{id: "yepochs.snapshot", version: 2})
      refute Algorithm.supports?(%Algorithm{id: "yepochs.snapshot", version: 1})
      refute Algorithm.supports?(%Algorithm{id: "yepochs.nonexistent", version: 1})
    end
  end

  describe "snapshot/2 honours an explicitly requested version" do
    test "accepts the version this build implements", %{doc: doc} do
      assert {:ok, s} =
               Yepochs.snapshot(doc, algorithm: %Algorithm{id: "yepochs.snapshot", version: 3})

      assert s.algorithm.version == 3
    end

    test "⛔ REFUSES a version it does not implement, rather than substituting", %{doc: doc} do
      assert {:error, %Error{code: :incompatible_algorithm, phase: :snapshot} = err} =
               Yepochs.snapshot(doc, algorithm: %Algorithm{id: "yepochs.snapshot", version: 4})

      assert err.details.requested.version == 4
      assert err.details.supported != []
    end

    test "refuses a version 1 replay request, because this build cannot reproduce it", %{doc: doc} do
      # The dangerous direction: an old durable artifact replayed under a newer
      # algorithm would produce different bytes under the same version tag.
      assert {:error, %Error{code: :incompatible_algorithm}} =
               Yepochs.snapshot(doc, algorithm: %Algorithm{id: "yepochs.snapshot", version: 1})
    end

    test "refuses an algorithm belonging to a different operation", %{doc: doc} do
      assert {:error, %Error{code: :incompatible_algorithm}} =
               Yepochs.snapshot(doc, algorithm: Algorithm.rebase())
    end

    test "defaults to the current version when none is requested", %{doc: doc} do
      assert {:ok, s} = Yepochs.snapshot(doc, [])
      assert s.algorithm == Algorithm.snapshot()
    end
  end

  describe "translate/4 and cross/5 honour an explicit version" do
    test "translate accepts its own algorithm", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      b = bridge([span(100, 0, 500, 0, 8)])
      assert {:ok, _} = Yepochs.translate(u, b, :left, algorithm: Algorithm.translate())
    end

    test "translate refuses an unavailable version", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      b = bridge([span(100, 0, 500, 0, 8)])

      assert {:error, %Error{code: :incompatible_algorithm}} =
               Yepochs.translate(u, b, :left,
                 algorithm: %Algorithm{id: "yepochs.translate", version: 9}
               )
    end

    test "cross refuses an unavailable version", %{source: source, dest: dest} do
      u = Updates.insert_delta(source, 200, 2, "XY")

      assert {:error, %Error{code: :incompatible_algorithm}} =
               Yepochs.cross(bridge([]), u, source, dest,
                 from: :left,
                 author: 1,
                 receipt_ref: "r",
                 algorithm: %Algorithm{id: "yepochs.cross", version: 7}
               )
    end
  end

  describe "§15.1 — the endpoint state must be the one the edit was authored against" do
    test "⛔ refuses a source_before whose causal dependencies the update does not meet",
         %{dest: dest} do
      # An update authored over a DIFFERENT base: applying it to this source
      # leaves it unintegrated in the pending buffer, which proves the supplied
      # state is not the one the edit was authored against.
      other_base = Updates.base("zzzzzzzz", 777)
      u = Updates.insert_delta(other_base, 200, 2, "XY")
      unrelated = Updates.base("abcdefgh", 100)

      assert {:error, %Error{code: :missing_endpoint_state, phase: :cross} = err} =
               Yepochs.cross(bridge([]), u, unrelated, dest,
                 from: :left,
                 author: 9000,
                 receipt_ref: "r"
               )

      assert err.details.pending > 0
    end

    test "accepts the state the edit WAS authored against", %{source: source, dest: dest} do
      u = Updates.insert_delta(source, 200, 2, "XY")

      assert {:ok, _} =
               Yepochs.cross(bridge([]), u, source, dest,
                 from: :left,
                 author: 9000,
                 receipt_ref: "r"
               )
    end
  end

  describe "documentation cannot drift from the algorithm it documents" do
    test "Snapshotter's moduledoc states the version Algorithm.snapshot/0 actually reports" do
      # ⛔ Caught by commonplace-merkle-crdt, not by this suite: the moduledoc
      # said "version 2" while Algorithm.snapshot/0 returned 3. They read the
      # version off the returned struct, which is what saved them — but a reader
      # who trusted the doc would have bound the WRONG version into an epoch
      # token, and the token would have been stable, plausible, and wrong.
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(Yepochs.Snapshotter)

      stated =
        ~r/algorithm `yepochs\.snapshot` \*\*version (\d+)\*\*/
        |> Regex.run(moduledoc)
        |> case do
          [_, n] -> String.to_integer(n)
          nil -> flunk("Snapshotter's moduledoc no longer states its algorithm version")
        end

      assert stated == Yepochs.Algorithm.snapshot().version
    end
  end

  describe "an empty observable state snapshots rather than refusing" do
    test "an empty document and a fully tombstoned one both succeed with zero spans" do
      # ⭐ Pinned because merkle-crdt's opener path depends on it: they refuse an
      # empty head themselves as {:empty_head, head}. If this layer started
      # refusing instead, their refusal would become unreachable and the error a
      # caller sees would change identity.
      empty = Yelixer.Doc.new(client_id: 100)

      tombstoned =
        Yelixer.Doc.new(client_id: 100)
        |> Yelixer.Types.Text.insert("t", 0, "hello")
        |> Yelixer.Types.Text.delete("t", 0, 5)

      {:ok, materialized} =
        Yelixer.Encoding.apply_update(
          Yelixer.Doc.new(client_id: 100),
          Yelixer.Encoding.encode_update(tombstoned)
        )

      for doc <- [empty, materialized] do
        assert {:ok, snapshot} = Yepochs.Snapshotter.snapshot(doc)
        assert snapshot.derivation.spans == []
        assert byte_size(snapshot.update) <= 2
      end

      # ⛔ CONTROL: a document WITH live content must not also produce an empty
      # snapshot, or the assertions above are satisfied by a snapshotter that
      # emits nothing for everything.
      {:ok, live} =
        Yelixer.Encoding.apply_update(
          Yelixer.Doc.new(client_id: 100),
          Yelixer.Encoding.encode_update(
            Yelixer.Types.Text.insert(Yelixer.Doc.new(client_id: 100), "t", 0, "hi")
          )
        )

      assert {:ok, live_snapshot} = Yepochs.Snapshotter.snapshot(live)
      assert live_snapshot.derivation.spans != []
      assert byte_size(live_snapshot.update) > 2
    end
  end
end
