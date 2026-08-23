defmodule Yepochs.Translator do
  @moduledoc """
  Strict, identity-preserving translation. Spec r2 §15.3–§15.10.

  Runs preflight first and consumes its plan rather than repeating the lookup
  logic, so the decision about every reference is made exactly once (§16).

  ⭐ **This is the low-level API.** Unlike `cross/5` it *does* surface
  missing-mapping and identity-collision errors: those are strict-path
  diagnostics, and under the high-level crossing they select positional
  re-authoring instead (§15.3).

  ⛔ **It never emits a partial update.** Preflight either produces a complete
  plan or the translation fails.
  """

  alias Yelixer.DeleteSet
  alias Yelixer.Encoding
  alias Yelixer.ID
  alias Yelixer.Item
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Limits
  alias Yepochs.Preflight
  alias Yepochs.Span
  alias Yepochs.Translation
  alias Yepochs.Update

  @doc """
  `direction` names the endpoint in which the update was authored; the other
  endpoint is the destination.
  """
  @spec translate(binary() | Update.t(), Bridge.t(), Preflight.direction(), keyword()) ::
          {:ok, Translation.t()} | {:error, Error.t()}
  def translate(update_or_binary, %Bridge{} = bridge, direction, opts \\ []) do
    limits = Limits.from_opts(opts)

    with {:ok, algorithm} <- Algorithm.resolve(opts, Algorithm.translate(), :translate),
         {:ok, update} <- decode(update_or_binary, limits),
         {:ok, plan} <- Preflight.run(update, bridge, direction, opts),
         {:ok, carried} <- carried_derivation(plan),
         encoded = Encoding.encode_items(Enum.map(update.items, &rewrite_item(&1, plan)), delete_set(plan)),
         :ok <- Limits.check(limits, :max_output_bytes, byte_size(encoded), :translate) do
      {:ok, %Translation{update: encoded, carried: carried, algorithm: algorithm}}
    end
  end

  defp decode(%Update{} = update, _limits), do: {:ok, update}
  defp decode(binary, limits) when is_binary(binary), do: Update.decode(binary, limits)
  defp decode(_, _), do: {:error, Error.new(:malformed_update, :translate)}

  # §15.4: an owned item keeps its client, clock and length. §15.6/§15.7: every
  # external reference is replaced from the plan. A reference the plan does not
  # carry is one the update owns, and is left exactly as authored.
  defp rewrite_item(%Item{} = item, plan) do
    %Item{
      item
      | origin: rewrite_ref(item.origin, plan.anchors),
        right_origin: rewrite_ref(item.right_origin, plan.anchors),
        parent: rewrite_parent(item.parent, plan.parents)
    }
  end

  defp rewrite_ref(nil, _map), do: nil

  defp rewrite_ref(%ID{client: c, clock: k} = id, map) do
    case Map.fetch(map, {c, k}) do
      {:ok, {dc, dk}} -> %ID{client: dc, clock: dk}
      :error -> id
    end
  end

  # A named root parent is not an item coordinate and MUST remain unchanged.
  defp rewrite_parent({:named, _} = parent, _map), do: parent
  defp rewrite_parent({:id, %ID{} = id}, map), do: {:id, rewrite_ref(id, map)}

  # ⚠️ `{:infer, id}` is yelixer's decode-time record of a parent that was NOT
  # on the wire, because Yjs omits the parent whenever an origin is present and
  # recovers it during integration. It is identity-bearing all the same, and
  # §15.9 forbids copying an identity-bearing field through unchanged -- so it
  # is translated rather than passed along, even though the encoder (verified:
  # "write parent if no origin and no right_origin") cannot currently emit it.
  # A test pins that no source coordinate survives in ANY identity field.
  defp rewrite_parent({:infer, %ID{} = id}, map), do: {:infer, rewrite_ref(id, map)}

  defp rewrite_parent(other, _map), do: other

  # §15.8: the delete set is rebuilt from translated coordinates. Reusing the
  # source delete set unchanged is non-conforming even when anchors were
  # translated. DeleteSet.insert/4 takes a LENGTH and stores half-open ranges.
  # No pre-sort: `DeleteSet.add_range/2` restores the sorted-disjoint invariant
  # on every insert, so insertion order cannot reach the bytes. Measured, not
  # assumed -- 0 of 676 concurrent-delete pairs produced differing delete sets
  # (docs/design/0002-encode-determinism.md). A sort here would look like a
  # determinism gate while being unable to fail.
  defp delete_set(%Preflight{deletes: deletes}) do
    Enum.reduce(deletes, DeleteSet.new(), fn {client, clock, len}, ds ->
      DeleteSet.insert(ds, client, clock, len)
    end)
  end

  # §15.4: destination coordinate == authored coordinate, in local orientation.
  defp carried_derivation(%Preflight{owned: owned}) do
    owned
    |> Enum.map(fn {client, clock, len} ->
      %Span{
        left_client: client,
        left_clock: clock,
        right_client: client,
        right_clock: clock,
        length: len
      }
    end)
    |> Derivation.new()
    |> case do
      {:ok, derivation} -> Derivation.normalize(derivation)
      {:error, _} = error -> error
    end
  end
end
