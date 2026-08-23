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
  alias Yepochs.Bridge
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Update

  @enforce_keys [:direction, :owned, :anchors, :parents, :deletes, :algorithm]
  defstruct @enforce_keys

  @type direction :: :left | :right
  @type item_ref :: {non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          direction: direction(),
          owned: [Update.interval()],
          anchors: %{item_ref() => item_ref()},
          parents: %{item_ref() => item_ref()},
          deletes: [{non_neg_integer(), non_neg_integer(), pos_integer()}],
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
    with :ok <- Derivation.validate(bridge.correspondence),
         :ok <- reject_unsupported(update),
         owned = Update.owned_intervals(update),
         :ok <- check_collisions(owned, bridge, direction, opts),
         {:ok, resolved} <- resolve_refs(update, bridge, direction) do
      {:ok,
       %__MODULE__{
         direction: direction,
         owned: owned,
         anchors: resolved.anchors,
         parents: resolved.parents,
         deletes: resolved.deletes,
         algorithm: Algorithm.translate()
       }}
    end
  end

  def run(binary, %Bridge{} = bridge, direction, opts)
      when is_binary(binary) and direction in [:left, :right] do
    with {:ok, update} <- Update.decode(binary), do: run(update, bridge, direction, opts)
  end

  def run(_binary, %Bridge{}, direction, _opts) do
    {:error, Error.new(:invalid_derivation, :preflight, path: [:direction], details: %{got: direction})}
  end

  # §15.9 — an identity-bearing field the translator does not understand must
  # not be copied through unchanged.
  defp reject_unsupported(update) do
    case Update.unsupported_features(update) do
      [] -> :ok
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
      [] -> :ok
      refs ->
        {:error,
         Error.new(:target_identity_collision, :preflight,
           refs: refs,
           details: %{
             failures:
               Enum.map(refs, &%{field: :owned_identity, code: :target_identity_collision, ref: &1})
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
  defp resolve_refs(update, bridge, direction) do
    {resolved, failures} =
      update
      |> Update.external_refs()
      |> Enum.reduce({%{anchors: %{}, parents: %{}, deletes: []}, []}, fn entry, {acc, fails} ->
        case resolve_entry(entry, bridge, direction) do
          {:ok, key, value} -> {put_resolved(acc, entry.field, key, value), fails}
          {:error, failure} -> {acc, [failure | fails]}
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

  defp resolve_entry(%{field: :delete, ref: {client, clock}, length: len}, bridge, direction) do
    # Range arithmetic, one contiguous run at a time (§15.8).
    Enum.reduce_while(0..(len - 1), {:ok, nil, []}, fn n, {:ok, _, acc} ->
      case translate_ref(bridge, direction, {client, clock + n}) do
        {:ok, dest} -> {:cont, {:ok, nil, [dest | acc]}}
        :unmapped ->
          {:halt,
           {:error,
            %{field: :delete, code: :missing_operation_target, ref: {client, clock + n}}}}
      end
    end)
    |> case do
      {:ok, _, refs} -> {:ok, :delete, coalesce_refs(Enum.reverse(refs))}
      {:error, _} = error -> error
    end
  end

  defp resolve_entry(%{field: field, ref: ref}, bridge, direction) do
    case translate_ref(bridge, direction, ref) do
      {:ok, dest} -> {:ok, ref, dest}
      :unmapped -> {:error, %{field: field, code: missing_code(field), ref: ref}}
    end
  end

  defp missing_code(:origin), do: :missing_anchor
  defp missing_code(:right_origin), do: :missing_anchor
  defp missing_code(:parent), do: :missing_operation_target

  defp put_resolved(acc, :delete, _key, ranges), do: %{acc | deletes: acc.deletes ++ ranges}
  defp put_resolved(acc, :parent, key, value), do: %{acc | parents: Map.put(acc.parents, key, value)}
  defp put_resolved(acc, _anchor, key, value), do: %{acc | anchors: Map.put(acc.anchors, key, value)}

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
  defp failure_error([first | _] = failures) do
    Error.new(first.code, :preflight,
      refs: Enum.map(failures, & &1.ref),
      details: %{failures: failures}
    )
  end
end
