defmodule Yepochs.Preflight do
  @moduledoc """
  Strict-translation preflight. Spec r2 §16.

  Performs every validation strict translation needs **without producing any
  translated bytes**, and returns a deterministic plan the translator consumes
  rather than repeating the lookup logic (§16).

  ⭐ **A preflight failure is a strict-path diagnostic, not a verdict on the
  edit.** Under `cross/5` a missing reference or an identity collision *selects
  positional re-authoring* when the edit lies within the supported data model
  (§16, §27.4). `translate/4` surfaces these errors because it is the low-level
  API; `cross/5` must not.
  """

  alias Yepochs.Algorithm
  alias Yelixer.BlockStore
  alias Yelixer.DeleteSet
  alias Yelixer.Doc
  alias Yepochs.Bridge
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Limits
  alias Yepochs.Update

  @enforce_keys [:direction, :owned, :anchors, :parents, :deletes, :omitted, :algorithm]
  defstruct @enforce_keys

  @type direction :: :left | :right
  @type item_ref :: {non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          direction: direction(),
          owned: [Update.interval()],
          anchors: %{item_ref() => item_ref()},
          parents: %{item_ref() => item_ref()},
          deletes: [{non_neg_integer(), non_neg_integer(), pos_integer()}],
          omitted: [{non_neg_integer(), non_neg_integer(), pos_integer()}],
          algorithm: Algorithm.t()
        }

  @doc """
  `direction` names the endpoint in which the update was **authored**; the other
  endpoint is the destination.
  """
  @spec run(binary() | Update.t(), Bridge.t(), direction(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def run(update_or_binary, bridge, direction, opts \\ [])

  def run(%Update{} = update, %Bridge{} = bridge, direction, opts)
      when direction in [:left, :right] do
    limits = Limits.from_opts(opts)

    with :ok <- Derivation.validate(bridge.correspondence),
         :ok <-
           Limits.check(limits, :max_spans, length(bridge.correspondence.spans), :preflight),
         :ok <- reject_unsupported(update),
         owned = Update.owned_intervals(update),
         :ok <- check_collisions(owned, bridge, direction, opts),
         {:ok, resolved} <- resolve_refs(update, bridge, direction, opts) do
      {:ok,
       %__MODULE__{
         direction: direction,
         owned: owned,
         anchors: resolved.anchors,
         parents: resolved.parents,
         deletes: resolved.deletes,
         omitted: Enum.sort(resolved.omitted),
         algorithm: Algorithm.translate()
       }}
    end
  end

  def run(binary, %Bridge{} = bridge, direction, opts)
      when is_binary(binary) and direction in [:left, :right] do
    with {:ok, update} <- Update.decode(binary, Limits.from_opts(opts)),
         do: run(update, bridge, direction, opts)
  end

  def run(_binary, %Bridge{}, direction, _opts) do
    {:error,
     Error.new(:invalid_derivation, :preflight, path: [:direction], details: %{got: direction})}
  end

  # §15.9 — an identity-bearing field the translator does not understand must
  # not be copied through unchanged.
  defp reject_unsupported(update) do
    case Update.unsupported_features(update) do
      [] ->
        :ok

      features ->
        {:error,
         Error.new(:unsupported_translation_feature, :preflight, details: %{features: features})}
    end
  end

  # Translating from the authored endpoint to the destination endpoint.
  defp translate_ref(bridge, :left, ref), do: Bridge.right_ref(bridge, ref)
  defp translate_ref(bridge, :right, ref), do: Bridge.left_ref(bridge, ref)

  # The destination side's own coordinates, as seen by the bridge.
  defp destination_ref(bridge, :left, ref), do: Bridge.left_ref(bridge, ref)
  defp destination_ref(bridge, :right, ref), do: Bridge.right_ref(bridge, ref)

  # §15.5. An owned identity cannot be preserved if that raw coordinate already
  # means a DIFFERENT item at the destination. The same identity mapping is fine.
  defp check_collisions(owned, bridge, direction, opts) do
    inventory = Keyword.get(opts, :destination_intervals, [])

    collisions =
      for {client, clock, len} <- owned,
          n <- 0..(len - 1),
          ref = {client, clock + n},
          collides?(ref, bridge, direction, inventory),
          do: ref

    case Enum.sort(collisions) do
      [] ->
        :ok

      refs ->
        {:error,
         Error.new(:target_identity_collision, :preflight,
           refs: refs,
           details: %{
             failures:
               Enum.map(
                 refs,
                 &%{field: :owned_identity, code: :target_identity_collision, ref: &1}
               )
           }
         )}
    end
  end

  defp collides?(ref, bridge, direction, inventory) do
    bridge_collision =
      case destination_ref(bridge, direction, ref) do
        # The destination coordinate is spoken for. Fine only if it corresponds
        # to this very coordinate — i.e. the correspondence is the identity.
        {:ok, authored} -> authored != ref
        :unmapped -> false
      end

    bridge_collision or occupied?(ref, inventory)
  end

  defp occupied?({client, clock}, inventory) do
    Enum.any?(inventory, fn {c, k, len} -> c == client and clock >= k and clock < k + len end)
  end

  # §15.6, §15.7, §15.8 in one deterministic pass, collecting EVERY failure
  # rather than stopping at the first.
  defp resolve_refs(update, bridge, direction, opts) do
    ctx = omission_context(bridge, direction, opts)

    {resolved, failures} =
      update
      |> Update.external_refs()
      |> Enum.reduce({%{anchors: %{}, parents: %{}, deletes: [], omitted: []}, []}, fn entry,
                                                                                       {acc,
                                                                                        fails} ->
        case resolve_entry(entry, bridge, direction, ctx) do
          {:ok, key, value} ->
            {put_resolved(acc, entry.field, key, value), fails}

          {:ok, :delete, ranges, omitted} ->
            {%{put_resolved(acc, :delete, nil, ranges) | omitted: acc.omitted ++ omitted}, fails}

          {:error, failure} ->
            {acc, [failure | fails]}
        end
      end)

    case Enum.sort_by(failures, &{&1.field, &1.ref}) do
      [] -> {:ok, %{resolved | deletes: preserved_deletes(update) ++ resolved.deletes}}
      sorted -> {:error, failure_error(sorted)}
    end
  end

  # A delete range covering clocks the update owns is preserved unchanged.
  # ⚠️ DeleteSet ranges are half-open {start, stop}, not {clock, length}.
  defp preserved_deletes(%Update{delete_set: %{clients: clients}} = update) do
    for {client, ranges} <- clients,
        {start, stop} <- ranges,
        clock <- start..(stop - 1)//1,
        Update.owns?(update, {client, clock}),
        do: {client, clock, 1}
  end

  # §15.8 plus ruling 3. Each clock of a delete interval is classified as
  # translated, checked-historical (omitted), or novel-and-uncovered (a failure),
  # so a MIXED interval splits into independently handled subranges.
  defp resolve_entry(%{field: :delete, ref: {client, clock}, length: len}, bridge, direction, ctx) do
    Enum.reduce_while(0..(len - 1), {:ok, [], []}, fn n, {:ok, mapped, omitted} ->
      coord = {client, clock + n}

      case translate_ref(bridge, direction, coord) do
        {:ok, dest} ->
          {:cont, {:ok, [dest | mapped], omitted}}

        :unmapped ->
          if omissible?(coord, ctx) do
            {:cont, {:ok, mapped, [coord | omitted]}}
          else
            {:halt, {:error, %{field: :delete, code: :missing_operation_target, ref: coord}}}
          end
      end
    end)
    |> case do
      {:ok, mapped, omitted} ->
        {:ok, :delete, coalesce_refs(Enum.reverse(mapped)), coalesce_refs(Enum.reverse(omitted))}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_entry(%{field: field, ref: ref}, bridge, direction, _ctx) do
    case translate_ref(bridge, direction, ref) do
      {:ok, dest} -> {:ok, ref, dest}
      :unmapped -> {:error, %{field: field, code: missing_code(field), ref: ref}}
    end
  end

  defp missing_code(:origin), do: :missing_anchor
  defp missing_code(:right_origin), do: :missing_anchor
  defp missing_code(:parent), do: :missing_operation_target

  defp put_resolved(acc, :delete, _key, ranges), do: %{acc | deletes: acc.deletes ++ ranges}

  defp put_resolved(acc, :parent, key, value),
    do: %{acc | parents: Map.put(acc.parents, key, value)}

  defp put_resolved(acc, _anchor, key, value),
    do: %{acc | anchors: Map.put(acc.anchors, key, value)}

  # Adjacent destination coordinates rejoin into one range; a non-contiguous
  # mapping splits the interval (§15.8).
  defp coalesce_refs(refs) do
    Enum.reduce(refs, [], fn {c, k}, acc ->
      case acc do
        [{pc, pk, plen} | rest] when pc == c and pk + plen == k -> [{pc, pk, plen + 1} | rest]
        _ -> [{c, k, 1} | acc]
      end
    end)
    |> Enum.reverse()
  end

  # Failures are ordered by {field, ref}; the reported code is the first in that
  # order, and details carries every failure so the caller can see all of them.
  # ⛔ Ruling 3: omission is permitted ONLY with the exact endpoint states, and
  # only after three proofs. Without them the context is `nil` and every
  # uncovered coordinate fails — `translate/4` stays conservative by construction
  # rather than by remembering to.
  defp omission_context(bridge, direction, opts) do
    with %Doc{} = before <- Keyword.get(opts, :source_before),
         %Doc{} <- Keyword.get(opts, :destination),
         true <- basis_complete?(bridge, direction, before) do
      %{before: before}
    else
      _ -> nil
    end
  end

  # ⚠️ Likewise not independently testable: a fabricated empty `source_before`
  # authorises nothing, because an empty delete set makes every coordinate
  # non-historical. The nil clause is the structural guarantee — `translate/4`
  # never supplies endpoint states, so it can never omit.
  defp omissible?(_coord, nil), do: false

  defp omissible?({client, clock}, %{before: before}) do
    # (a) The range was already deleted before this edit. Otherwise omitting it
    #     would discard a real deletion.
    #
    # (b) Bridge completeness over live source content was established when the
    #     context was built.
    #
    # (c) The destination holds no live item requiring this deletion — which
    #     FOLLOWS from (a) and (b) rather than needing its own lookup: every live
    #     source clock is mapped, this clock is unmapped, therefore it is not
    #     live source content, therefore nothing in the destination was
    #     re-authored from it.
    #
    # ⛔ An earlier version checked the destination for a live item at the SAME
    # RAW COORDINATE. That is wrong and dangerously so: the snapshot mints under
    # the smallest source client id, so a destination routinely holds live items
    # at coordinates numerically equal to source tombstones. Comparing them is
    # raw numeric equality ACROSS EPOCHS — precisely what invariant 1 and
    # invariant 9 forbid. It made every legitimate omission fail.
    #
    # ⚠️ Mutation testing shows this check cannot currently be made to fail, and
    # that is a PROOF rather than a coverage gap: under (b), every live source
    # clock is mapped, so a NOVEL delete — which by definition targets content
    # that was live before the edit — is always covered and never reaches here.
    # The check is therefore redundant *given* (b) and kept as defence in depth
    # against (b) being weakened. It is not counted as a tested gate.
    DeleteSet.deleted?(before.delete_set, client, clock)
  end

  # (b) Every LIVE clock of the source is covered by the bridge. Only then can an
  # uncovered-and-dead coordinate be concluded to have never been re-authored
  # into the destination at all.
  defp basis_complete?(bridge, direction, %Doc{store: store} = before) do
    store
    |> BlockStore.all_items()
    |> Enum.reject(& &1.deleted)
    |> Enum.filter(&match?({:named, _}, &1.parent))
    |> Enum.all?(fn item ->
      Enum.all?(0..(item.length - 1)//1, fn n ->
        coord = {item.id.client, item.id.clock + n}

        DeleteSet.deleted?(before.delete_set, elem(coord, 0), elem(coord, 1)) or
          match?({:ok, _}, translate_ref(bridge, direction, coord))
      end)
    end)
  end

  defp failure_error([first | _] = failures) do
    Error.new(first.code, :preflight,
      refs: Enum.map(failures, & &1.ref),
      details: %{failures: failures}
    )
  end
end
