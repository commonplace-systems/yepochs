defmodule Yepochs.Snapshotter do
  @moduledoc """
  Deterministic snapshotting, algorithm `yepochs.snapshot` version 2.
  Spec r2 §10.

  The re-authoring itself is `Yelixer.Doc.snapshot_update/1`; version 2's own
  contribution is the **deterministic minter**: the source doc's `client_id` is
  overwritten with the smallest client id present in its items (0 when empty),
  so two independent reconstructions of the same logical state produce
  byte-identical output (§10.3).

  ## ⛔ Two corrections this makes to the experimental behaviour

  **1. The derivation is built from clock SPANS, not item-start pairs (§27.1).**
  The experimental derivation map paired item starts by position. Measured: a
  document written as eight one-character inserts is replayed as a single
  eight-clock item, and the item-start map then covers **1 of 8 clocks** — so
  §10.5 ("the derivation MUST cover every emitted clock") is unsatisfiable in
  that shape. This module walks both clock streams instead and emits maximal
  spans, which is also what makes a reference *into the middle* of a
  consolidated item resolvable.

  **2. Observable equivalence is CHECKED, not assumed (§10.2).**
  Measured: `Yelixer.Doc.snapshot_update/1` replays by iterating the source
  doc's **type registry**, so a doc holding content under a name its `types` map
  does not list is snapshotted to an **empty document** — bytes, no error, no
  warning. Commonplace hit this exact trap (its `CX-saix` note: *"an xml outline
  snapshotted to EMPTY"*) and worked around it by hydrating the registry at the
  call site.

  ⛔ A caller-side workaround cannot protect this library's contract, so the
  post-condition is enforced here: the clock stream of the re-authored document
  must match the source's, or the snapshot is refused with
  `:unsupported_content` — which is precisely what §10.2 requires when an
  encountered shared type cannot be preserved. **It MUST NOT silently omit,
  stringify, or flatten it.**

  ## ⚠️ Determinism is over the exact `Doc` REPRESENTATION

  > Byte determinism is defined over the exact Yelixer `Doc` representation
  > supplied by the caller, including item identities, struct boundaries, and
  > arrival-dependent internal representation. **Two Docs with the same
  > observable value but different internal representations are different
  > inputs.**

  ⛔ This library MUST NOT be read as canonicalizing across different valid
  internal representations of the same observable Yjs value. It is deterministic
  for one fixed exact input representation, algorithm version, adapter version,
  codec version, and option set — and measured evidence that the qualifier is
  load-bearing is in `docs/design/0002-encode-determinism.md`.
  """

  alias Yelixer.BlockStore
  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yepochs.Algorithm
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Snapshot
  alias Yepochs.Span

  @registry_remedy "the doc's type registry does not describe its store; round-trip it through Yelixer.Encoding.apply_update/2 before snapshotting"

  @spec snapshot(Doc.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def snapshot(%Doc{} = source, opts \\ []) do
    with {:ok, algorithm} <- Algorithm.resolve(opts, Algorithm.snapshot(), :snapshot),
         deterministic = %{source | client_id: deterministic_client_id(source)},
         {:ok, update} <- reauthor(deterministic),
         {:ok, rebuilt} <- decode_rebuilt(update),
         {:ok, derivation} <- derive(deterministic, rebuilt) do
      {:ok, %Snapshot{update: update, derivation: derivation, algorithm: algorithm}}
    end
  end

  # §10.3: the smallest client id among the source's items, or 0 when empty.
  # Smallest-by-integer is stable across nodes and does not depend on map
  # iteration order.
  defp deterministic_client_id(%Doc{} = doc) do
    case Doc.client_ids(doc) do
      [] -> 0
      clients -> Enum.min(clients)
    end
  end

  defp reauthor(%Doc{} = deterministic) do
    case Doc.snapshot_update(deterministic) do
      # The paired item-start map is discarded: see correction 1 above.
      {update, _item_start_map} when is_binary(update) ->
        {:ok, update}

      {:error, {:lossy_nested_subtypes, names}} ->
        {:error, Error.new(:unsupported_content, :snapshot, details: %{nested_subtypes: names})}

      {:error, reason} ->
        {:error, Error.new(:unsupported_content, :snapshot, details: %{reason: inspect(reason)})}
    end
  end

  defp decode_rebuilt(update) do
    case Encoding.apply_update(Doc.new(client_id: 0), update) do
      {:ok, doc} -> {:ok, doc}
      _ -> {:error, Error.new(:malformed_update, :snapshot)}
    end
  end

  # ⭐ The pairing does NOT try to replicate the replay's internal traversal.
  # It only needs a rule T such that T(source) and T(derived) enumerate
  # CORRESPONDING content in the same order — the two documents hold the same
  # observable state, so any content-structural traversal pairs them correctly,
  # whatever order the replay happened to emit in.
  #
  # ⛔ Pairing by client-grouped item order (what the experimental derivation map
  # does) is NOT such a rule: it groups by identity, and identity is exactly
  # what the snapshot replaces. Measured — for a two-client document it pairs
  # source "X" with derived "c".
  defp derive(%Doc{} = source, %Doc{} = rebuilt) do
    left = content_stream(source)
    right = content_stream(rebuilt)

    # §10.2's post-condition, enforced rather than assumed.
    #
    # ⚠️ The reference count comes from the STORE, not from `content_stream/1`:
    # the replay is driven by the source's type registry, so a type missing from
    # that registry is invisible to both the replay AND to a registry-derived
    # count. Comparing a registry-derived number against itself would agree
    # perfectly while the snapshot came out empty.
    actual = observable_clock_count(source)

    cond do
      length(left) != length(right) or actual != length(right) ->
        counts = %{
          source_clocks: actual,
          traversed_clocks: length(left),
          derived_clocks: length(right)
        }

        {:error,
         Error.new(:unsupported_content, :snapshot, details: Map.merge(counts, cause(source)))}

      true ->
        left
        |> Enum.zip(right)
        |> spans()
        |> Derivation.new()
        |> case do
          {:ok, derivation} -> Derivation.normalize(derivation)
          {:error, _} = error -> error
        end
    end
  end

  # ⭐ The two causes of `:unsupported_content` are NOT interchangeable, and a
  # caller cannot act sensibly on them the same way.
  #
  #   * `:unregistered_types` — the type registry does not describe the store's
  #     content, so the replay has nothing to iterate. A locally-authored `Doc`
  #     is in this state: its items sit in `client_pending` and `types` is
  #     empty. ⇒ The content is bridgeable; only this doc is not, and one
  #     round-trip through `apply_update/2` fixes it. So the remedy is REPORTED.
  #
  #   * `:nested_type_children` — an item whose content is a nested type
  #     instance. `snapshot_update/1` does not re-author those, so the derived
  #     document cannot hold the source's observable content and NO
  #     correspondence exists to bridge. ⇒ There is no caller-side remedy, and
  #     none is offered: `docs/design/0006-totality-classification.md` §2.
  #
  # ⚠️ Nested-type content is checked FIRST. A doc can be in both states at once,
  # and reporting the remediable cause for a document that also holds an
  # unbridgeable child would send the caller round a round-trip that cannot help.
  defp cause(%Doc{} = source) do
    cond do
      nested_type_children?(source) -> %{cause: :nested_type_children}
      unregistered_types?(source) -> %{cause: :unregistered_types, remedy: @registry_remedy}
      true -> %{cause: :unknown}
    end
  end

  defp nested_type_children?(%Doc{store: store}) do
    store
    |> BlockStore.all_items()
    |> Enum.reject(& &1.deleted)
    |> Enum.any?(&match?({:type, _}, &1.content))
  end

  # The registry is silent about content the store holds under a named parent.
  defp unregistered_types?(%Doc{types: types, store: store}) do
    named =
      store
      |> BlockStore.all_items()
      |> Enum.reject(& &1.deleted)
      |> Enum.flat_map(fn
        %{parent: {:named, name}} -> [name]
        _ -> []
      end)
      |> MapSet.new()

    not MapSet.subset?(named, MapSet.new(Map.keys(types)))
  end

  # Every live clock the store actually holds under ANY named parent.
  #
  # ⛔ Synthetic names are deliberately NOT excluded here, even though the
  # traversal skips them. An XML element's children live under `name::children`,
  # and the replay does not re-author them -- measured: an element with one child
  # snapshots to an element with none, attributes intact. Excluding those names
  # from the reference count made that loss invisible to this very check, which
  # then reported success on a snapshot that had dropped content.
  #
  # Counting them means such a document is REFUSED with `:unsupported_content`,
  # which is what §10.2 requires: it MUST NOT silently omit, stringify, or
  # flatten content it cannot preserve.
  defp observable_clock_count(%Doc{store: store}) do
    store
    |> BlockStore.all_items()
    |> Enum.reject(& &1.deleted)
    |> Enum.filter(&match?({:named, _}, &1.parent))
    |> Enum.map(& &1.length)
    |> Enum.sum()
  end

  # Named types in NAME order — stable across both documents, unlike the
  # earliest-item order the replay uses, which depends on the very ids the
  # snapshot is replacing. Synthetic sub-type names are skipped: the replay does
  # not re-author them structurally.
  #
  # ⚠️ The `sort/0` is belt-and-braces, and mutation testing confirms it cannot
  # currently fail: `Map.keys/1` order is a function of the key SET, and both
  # documents carry the same type names, so they already enumerate alike. It is
  # kept because the alternative is a determinism-critical traversal whose order
  # rests on an unspecified property of the map implementation — but it is not a
  # tested gate and is not counted as one.
  defp content_stream(%Doc{types: types, store: store}) do
    types
    |> Map.keys()
    |> Enum.reject(&synthetic?/1)
    |> Enum.sort()
    |> Enum.flat_map(fn name -> sequence_clocks(store, name) ++ map_clocks(store, name) end)
  end

  defp synthetic?(name) do
    String.starts_with?(name, "__sub:") or String.contains?(name, "::child::") or
      String.ends_with?(name, "::children")
  end

  # The sequence plane, in document order. Tombstones are excluded: they are not
  # re-authored, and §10.5 makes no promise for them.
  #
  # ⚠️ `get_sequence/2` also returns map-plane items (those carrying a
  # `parent_sub`), so they must be excluded here or every map entry is counted
  # once in each plane. A named type has TWO storage planes under one name.
  defp sequence_clocks(store, name) do
    store
    |> BlockStore.get_sequence(name)
    |> Enum.reject(&(&1.deleted or &1.parent_sub != nil))
    |> Enum.flat_map(&clocks_of/1)
  end

  # The map plane, in key order — items carrying a `parent_sub`, which
  # `get_sequence/2` does not return.
  defp map_clocks(store, name) do
    store
    |> BlockStore.all_items()
    |> Enum.filter(fn item ->
      match?({:named, ^name}, item.parent) and item.parent_sub != nil and not item.deleted
    end)
    |> Enum.sort_by(& &1.parent_sub)
    |> Enum.flat_map(&clocks_of/1)
  end

  defp clocks_of(item) do
    for n <- 0..(item.length - 1)//1, do: {item.id.client, item.id.clock + n}
  end

  # Collapse the clock-by-clock pairing into maximal spans.
  defp spans(pairs) do
    pairs
    |> Enum.reduce([], fn {{lc, lk}, {rc, rk}}, acc ->
      case acc do
        [%Span{left_client: ^lc, right_client: ^rc} = prev | rest] ->
          if prev.left_clock + prev.length == lk and prev.right_clock + prev.length == rk,
            do: [%Span{prev | length: prev.length + 1} | rest],
            else: [new_span(lc, lk, rc, rk) | acc]

        _ ->
          [new_span(lc, lk, rc, rk) | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp new_span(lc, lk, rc, rk) do
    %Span{left_client: lc, left_clock: lk, right_client: rc, right_clock: rk, length: 1}
  end
end
