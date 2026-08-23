defmodule Yepochs.Update do
  @moduledoc """
  A decoded Yjs update, inventoried for strict translation. Spec r2 §15.4–§15.9.

  This is where the central distinction of §6.8/§6.9 becomes concrete:

  - an **owned identity** is a coordinate defined by an item struct *inside this
    update*. Strict translation preserves it, so references among items in the
    same update stay valid without any bridge lookup;
  - an **external reference** is an identity-bearing coordinate the update *uses*
    but does not define. It MUST be translated through the bridge, and ⛔ **must
    never be passed through merely because its numeric values look valid at the
    destination.**

  The identity-bearing sites are exactly four: `origin`, `right_origin`, an
  ID-valued `parent`, and delete-set targets. A **named root parent is not an
  item coordinate** and is never reported (§15.7).
  """

  alias Yelixer.DeleteSet
  alias Yelixer.Encoding
  alias Yelixer.ID
  alias Yelixer.Item
  alias Yepochs.Error
  alias Yepochs.Limits

  @enforce_keys [:items, :delete_set]
  defstruct @enforce_keys

  @type interval :: {non_neg_integer(), non_neg_integer(), pos_integer()}
  @type item_ref :: {non_neg_integer(), non_neg_integer()}

  @type ref_entry :: %{
          field: :origin | :right_origin | :parent | :delete,
          ref: item_ref(),
          length: pos_integer()
        }

  @type t :: %__MODULE__{items: [Item.t()], delete_set: DeleteSet.t()}

  # Content variants that carry no item coordinate. `{:type, ref}` holds a
  # TYPE reference (an xml tag or type tag), not an item coordinate -- verified
  # against yelixer's encoder rather than assumed.
  @known_content [:string, :json, :binary, :embed, :format, :any, :deleted, :gc, :type]

  @doc """
  Decodes an update binary. Never raises: yelixer's decoder catches malformed
  input and returns a typed tuple, which is mapped to `:malformed_update`.
  """
  @spec decode(binary(), Limits.t() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary, limits \\ [])

  def decode(binary, limits) when is_binary(binary) do
    limits = Limits.new(limits)

    # Checked BEFORE decoding: a size limit that only fires after the work is
    # done is not a limit.
    with :ok <- Limits.check(limits, :max_update_bytes, byte_size(binary), :preflight),
         {:ok, {items, delete_set, _rest}} <- decode_raw(binary),
         update = %__MODULE__{items: items, delete_set: delete_set},
         :ok <- Limits.check(limits, :max_structs, length(items), :preflight),
         :ok <- Limits.check(limits, :max_delete_intervals, delete_interval_count(update), :preflight),
         :ok <- Limits.check(limits, :max_depth, nesting_depth(update), :preflight) do
      {:ok, update}
    end
  end

  def decode(_, _), do: {:error, Error.new(:malformed_update, :preflight)}

  defp decode_raw(binary) do
    case Encoding.decode_update(binary) do
      {:ok, _} = ok -> ok
      {:error, {:malformed_update, message}} ->
        {:error, Error.new(:malformed_update, :preflight, details: %{reason: message})}
    end
  end

  defp delete_interval_count(%__MODULE__{delete_set: %DeleteSet{clients: clients}}) do
    clients |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
  end

  @doc "Longest chain of ID-valued parents within this update. Spec §23."
  @spec nesting_depth(t()) :: non_neg_integer()
  def nesting_depth(%__MODULE__{items: items}) do
    by_id = Map.new(items, fn i -> {{i.id.client, i.id.clock}, i} end)
    Enum.reduce(items, 0, fn item, acc -> max(acc, depth_of(item, by_id, 0)) end)
  end

  # Bounded by the item count, so a cyclic parent chain in hostile input cannot
  # loop forever.
  defp depth_of(_item, by_id, seen) when seen > map_size(by_id), do: seen

  defp depth_of(item, by_id, seen) do
    case structural_parent(item) do
      nil ->
        seen

      %ID{client: c, clock: k} ->
        case Map.fetch(by_id, {c, k}) do
          {:ok, parent} -> depth_of(parent, by_id, seen + 1)
          :error -> seen + 1
        end
    end
  end

  @doc """
  Every item interval this update defines, as `{client, clock, length}`,
  deterministically ordered. Spec §15.4.

  GC structs define no live identity and are excluded.
  """
  @spec owned_intervals(t()) :: [interval()]
  def owned_intervals(%__MODULE__{items: items}) do
    items
    |> Enum.reject(&gc?/1)
    |> Enum.map(fn %Item{id: %ID{client: c, clock: k}, length: len} -> {c, k, len} end)
    |> Enum.filter(fn {_, _, len} -> len > 0 end)
    |> Enum.sort()
  end

  defp gc?(%Item{content: {:gc, _}}), do: true
  defp gc?(%Item{}), do: false

  @doc "Whether `ref` falls inside an interval this update defines. Spec §15.4."
  @spec owns?(t(), item_ref()) :: boolean()
  def owns?(%__MODULE__{} = update, {client, clock}) do
    Enum.any?(owned_intervals(update), fn {c, k, len} ->
      c == client and clock >= k and clock < k + len
    end)
  end

  @doc """
  Every identity-bearing coordinate this update uses but does not define,
  deterministically ordered. Spec §15.6–§15.8.

  Delete-set coverage is reported as **ranges**, with owned sub-ranges removed —
  §15.8 requires range arithmetic rather than expanding one clock at a time.
  """
  @spec external_refs(t()) :: [ref_entry()]
  def external_refs(%__MODULE__{} = update) do
    (anchor_refs(update) ++ delete_refs(update))
    |> Enum.sort_by(&{&1.field, &1.ref})
  end

  defp anchor_refs(%__MODULE__{items: items} = update) do
    Enum.flat_map(items, fn %Item{} = item ->
      [{:origin, item.origin}, {:right_origin, item.right_origin}, {:parent, id_parent(item)}]
      |> Enum.flat_map(fn
        {_field, nil} -> []
        {field, %ID{client: c, clock: k}} -> external_entry(update, field, {c, k})
      end)
    end)
  end

  # A named root parent is not an item coordinate (§15.7).
  #
  # ⚠️ Only `{:id, _}` counts here. An `{:infer, _}` parent is yelixer's
  # decode-time note that the parent was NOT on the wire, so demanding a bridge
  # mapping for it would fail translations over references that are never
  # emitted. Depth measurement uses `structural_parent/1` instead, which does
  # count it, because nesting is about shape rather than about what is encoded.
  defp id_parent(%Item{parent: {:id, %ID{} = id}}), do: id
  defp id_parent(%Item{}), do: nil

  defp structural_parent(%Item{parent: {:id, %ID{} = id}}), do: id
  defp structural_parent(%Item{parent: {:infer, %ID{} = id}}), do: id
  defp structural_parent(%Item{}), do: nil

  defp external_entry(update, field, ref) do
    if owns?(update, ref), do: [], else: [%{field: field, ref: ref, length: 1}]
  end

  # ⚠️ yelixer's DeleteSet stores HALF-OPEN {start, stop} ranges, NOT
  # {clock, length}. `{2, 5}` means clocks 2, 3, 4 -- three clocks, not five.
  # Misreading this silently translates the wrong delete range, so it is pinned
  # by a test rather than left to a comment.
  defp delete_refs(%__MODULE__{delete_set: %DeleteSet{clients: clients}} = update) do
    Enum.flat_map(clients, fn {client, ranges} ->
      Enum.flat_map(ranges, fn {start, stop} ->
        client
        |> subtract_owned(start, stop - start, update)
        |> Enum.map(fn {k, l} -> %{field: :delete, ref: {client, k}, length: l} end)
      end)
    end)
  end

  # Remove the portions of [clock, clock+len) that this update owns: those
  # coordinates are preserved rather than translated (§15.8).
  defp subtract_owned(client, clock, len, update) do
    owned =
      update
      |> owned_intervals()
      |> Enum.filter(fn {c, _, _} -> c == client end)
      |> Enum.map(fn {_, k, l} -> {k, k + l} end)
      |> Enum.sort()

    Enum.reduce(owned, [{clock, clock + len}], fn {os, oe}, acc ->
      Enum.flat_map(acc, fn {s, e} ->
        cond do
          oe <= s or os >= e -> [{s, e}]
          true -> Enum.filter([{s, min(os, e)}, {max(oe, s), e}], fn {a, b} -> a < b end)
        end
      end)
    end)
    |> Enum.map(fn {s, e} -> {s, e - s} end)
  end

  @doc """
  Content variants this build cannot prove safe to rewrite. Spec §15.9.

  ⛔ An unknown identity-bearing field MUST NOT be copied through unchanged; it
  fails strict translation with `:unsupported_translation_feature`. `cross/5`
  may still re-author the edit if a positional adapter supports its content.
  """
  @spec unsupported_features(t()) :: [atom()]
  def unsupported_features(%__MODULE__{items: items}) do
    items
    |> Enum.map(fn %Item{content: content} -> elem(content, 0) end)
    |> Enum.reject(&(&1 in @known_content))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
