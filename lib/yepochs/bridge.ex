defmodule Yepochs.Bridge do
  @moduledoc """
  An evolving, **bidirectional** edit-compatibility relationship between two
  Yepochs. Spec r2 §6.6, §8.3, §11–§14, §17.

  ⭐ **A bridge has no permanent source or target.** Its endpoints are called
  `left` and `right` only to give persisted correspondence spans a stable
  orientation. For one crossing, the endpoint where the edit was authored is the
  source and the other is the destination; the roles reverse for an edit
  travelling the other way (§6.6).

  A bridge is an immutable value that evolves by applying append-only deltas
  (§17). Bridge evolution is monotonic: accepted correspondence and receipts are
  added, never silently rewritten or removed (invariant 12).
  """

  alias Yepochs.Algorithm
  alias Yepochs.Bridge.Basis
  alias Yepochs.Bridge.Delta
  alias Yepochs.Crossing.Receipt
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Span

  @format_version 1
  @max_epoch_ref_bytes 1024

  @enforce_keys [:format_version, :left_epoch, :right_epoch, :correspondence, :basis, :receipts]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          format_version: pos_integer(),
          left_epoch: String.t(),
          right_epoch: String.t(),
          correspondence: Derivation.t(),
          basis: Basis.t(),
          receipts: [Receipt.t()]
        }

  @type item_ref :: Span.item_ref()

  @doc """
  Spec §11. Validates both epoch references, validates and normalizes the
  derivation, rejects equal endpoints, assigns the **origin** to the bridge's
  left endpoint and the **derived** Yepoch to its right endpoint, and records
  that directed fact in `basis`.

  Attaching endpoint labels changes no span. ⭐ **Later use of the bridge is
  bidirectional regardless of its construction orientation.**
  """
  @spec attach(Derivation.t(), String.t(), String.t(), Algorithm.t()) ::
          {:ok, t()} | {:error, Error.t()}
  def attach(%Derivation{} = derivation, origin_epoch, derived_epoch, %Algorithm{} = producer) do
    basis = %Basis{kind: :snapshot, producer: producer, origin: :left, derived: :right}

    with :ok <- validate_epoch_ref(origin_epoch, :left_epoch),
         :ok <- validate_epoch_ref(derived_epoch, :right_epoch),
         :ok <- reject_equal_endpoints(origin_epoch, derived_epoch),
         :ok <- Basis.validate(basis),
         {:ok, normalized} <- Derivation.normalize(derivation) do
      {:ok,
       %__MODULE__{
         format_version: @format_version,
         left_epoch: origin_epoch,
         right_epoch: derived_epoch,
         correspondence: normalized,
         basis: basis,
         receipts: []
       }}
    end
  end

  # §6.3: an opaque, canonical UTF-8 string, compared byte-for-byte. Not
  # required to be a UUID, CID, hash, or Commonplace commit ID.
  defp validate_epoch_ref(ref, field) when is_binary(ref) do
    cond do
      not String.valid?(ref) -> epoch_error(field)
      byte_size(ref) == 0 -> epoch_error(field)
      byte_size(ref) > @max_epoch_ref_bytes -> epoch_error(field)
      true -> :ok
    end
  end

  defp validate_epoch_ref(_, field), do: epoch_error(field)

  defp reject_equal_endpoints(same, same), do: epoch_error(:endpoints)
  defp reject_equal_endpoints(_, _), do: :ok

  defp epoch_error(field), do: {:error, Error.new(:invalid_epoch_ref, :bridge, path: [field])}

  @doc """
  Given a coordinate in the **left** endpoint, return its right-endpoint
  counterpart. Spec §12.

  Resolves a reference to any clock inside a span, not only the first clock of
  an encoded Yjs item, and never falls back to the same numeric coordinate.

  ⚠️ **`:unmapped` exposes only the strict correspondence. It selects the
  crossing fallback; it does not prove that an edit cannot cross** (§12, §27.4).
  """
  @spec right_ref(t(), item_ref()) :: {:ok, item_ref()} | :unmapped
  def right_ref(%__MODULE__{} = bridge, {client, clock}),
    do: lookup(bridge.correspondence.spans, client, clock, :left)

  @doc "Given a coordinate in the **right** endpoint, return its left counterpart. Spec §12."
  @spec left_ref(t(), item_ref()) :: {:ok, item_ref()} | :unmapped
  def left_ref(%__MODULE__{} = bridge, {client, clock}),
    do: lookup(bridge.correspondence.spans, client, clock, :right)

  defp lookup(spans, client, clock, from) do
    {from_client, from_clock, to_client, to_clock} =
      case from do
        :left -> {:left_client, :left_clock, :right_client, :right_clock}
        :right -> {:right_client, :right_clock, :left_client, :left_clock}
      end

    Enum.find_value(spans, :unmapped, fn span ->
      base = Map.fetch!(span, from_clock)

      if Map.fetch!(span, from_client) == client and clock >= base and clock < base + span.length do
        {:ok, {Map.fetch!(span, to_client), Map.fetch!(span, to_clock) + (clock - base)}}
      end
    end)
  end

  @doc """
  Spec §13. Exchanges endpoint references, span coordinates, basis roles, and
  receipt sides, then normalizes.

  ⭐ **It does not produce a new logical relationship** — reorienting swaps
  presentation, not capability (invariant 6).
  """
  @spec invert(t()) :: {:ok, t()} | {:error, Error.t()}
  def invert(%__MODULE__{} = bridge) do
    with {:ok, flipped} <- Derivation.invert(bridge.correspondence) do
      {:ok,
       %__MODULE__{
         bridge
         | left_epoch: bridge.right_epoch,
           right_epoch: bridge.left_epoch,
           correspondence: flipped,
           basis: Basis.flip(bridge.basis),
           receipts: Enum.map(bridge.receipts, &Receipt.flip/1)
       }}
    end
  end

  @doc """
  Spec §14. Composes `A --ab--> B --bc--> C` into `A --ac--> C`, calculating the
  strict correspondence through the shared endpoint `A <-> B <-> C`.

  The resulting mapping may be smaller than either input because each
  correspondence is partial. ⛔ **Composition never invents missing item
  mappings** — an edit crossing the composed bridge uses positional re-authoring
  when strict preflight lacks coverage.

  Edge-specific crossing receipts are **left on their original bridges** rather
  than pretending they occurred directly between A and C (§14 item 7).
  """
  @spec compose([t()]) :: {:ok, t()} | {:error, Error.t()}
  def compose([]), do: {:error, Error.new(:bridge_endpoint_mismatch, :bridge, path: [:path])}
  def compose([%__MODULE__{} = only]), do: {:ok, only}

  def compose([%__MODULE__{} = first | rest]) do
    Enum.reduce_while(rest, {:ok, first}, fn next, {:ok, acc} ->
      case compose_pair(acc, next) do
        {:ok, composed} -> {:cont, {:ok, composed}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp compose_pair(%__MODULE__{} = ab, %__MODULE__{} = bc) do
    if ab.right_epoch != bc.left_epoch do
      {:error,
       Error.new(:bridge_endpoint_mismatch, :bridge,
         details: %{expected_left: ab.right_epoch, got_left: bc.left_epoch}
       )}
    else
      spans =
        for ab_span <- ab.correspondence.spans,
            bc_span <- bc.correspondence.spans,
            ab_span.right_client == bc_span.left_client,
            overlap = intersect(ab_span, bc_span),
            overlap != nil,
            do: overlap

      with {:ok, derivation} <- Derivation.new(spans),
           {:ok, normalized} <- Derivation.normalize(derivation) do
        {:ok,
         %__MODULE__{
           format_version: @format_version,
           left_epoch: ab.left_epoch,
           right_epoch: bc.right_epoch,
           correspondence: normalized,
           basis: %Basis{kind: :composition, producer: Algorithm.compose()},
           receipts: []
         }}
      end
    end
  end

  # Intersect over the shared intermediate (B) clock range, then re-express the
  # overlap as A <-> C.
  defp intersect(ab_span, bc_span) do
    lo = max(ab_span.right_clock, bc_span.left_clock)
    hi = min(Span.right_end(ab_span), Span.left_end(bc_span))

    if lo < hi do
      %Span{
        left_client: ab_span.left_client,
        left_clock: ab_span.left_clock + (lo - ab_span.right_clock),
        right_client: bc_span.right_client,
        right_clock: bc_span.right_clock + (lo - bc_span.left_clock),
        length: hi - lo
      }
    end
  end

  @doc """
  Spec §17. Applies an append-only delta from an admitted crossing.

  This is an admission record, not merely an optimization: the caller MUST
  persist the extension, or reconstruct it from accepted crossing records,
  before relying on it for a later strict translation.
  """
  @spec extend(t(), Delta.t()) :: {:ok, t()} | {:error, Error.t()}
  def extend(%__MODULE__{} = bridge, %Delta{} = delta) do
    with :ok <- Derivation.validate(delta.correspondence),
         :ok <- check_receipt(bridge.receipts, delta.receipt),
         :ok <- check_span_consistency(bridge.correspondence.spans, delta.correspondence.spans),
         {:ok, derivation} <-
           Derivation.new(merge_lines(bridge.correspondence.spans ++ delta.correspondence.spans)),
         {:ok, normalized} <- Derivation.normalize(derivation) do
      {:ok,
       %__MODULE__{
         bridge
         | correspondence: normalized,
           receipts: append_receipt(bridge.receipts, delta.receipt)
       }}
    end
  end

  # An exact duplicate receipt is idempotent; the SAME ref carrying a different
  # crossing result is a conflict, not an update — evolution is monotonic.
  defp check_receipt(existing, %Receipt{} = new) do
    case Enum.find(existing, &(&1.ref == new.ref)) do
      nil ->
        :ok

      ^new ->
        :ok

      _ ->
        {:error,
         Error.new(:receipt_conflict, :bridge, path: [:receipt], details: %{ref: new.ref})}
    end
  end

  defp append_receipt(existing, %Receipt{} = new) do
    if Enum.any?(existing, &(&1 == new)), do: existing, else: existing ++ [new]
  end

  # An overlap is admissible only when both spans lie on the same mapping line —
  # same client pair, same clock delta. Anything else would give one side two
  # meanings.
  defp check_span_consistency(existing, additions) do
    Enum.reduce_while(additions, :ok, fn add, :ok ->
      conflict =
        Enum.find(existing, fn old ->
          (overlaps?(old, add, :left) or overlaps?(old, add, :right)) and not same_line?(old, add)
        end)

      if conflict,
        do: {:halt, {:error, Error.new(:invalid_derivation, :bridge, path: [:extension])}},
        else: {:cont, :ok}
    end)
  end

  defp overlaps?(a, b, :left) do
    a.left_client == b.left_client and a.left_clock < Span.left_end(b) and
      b.left_clock < Span.left_end(a)
  end

  defp overlaps?(a, b, :right) do
    a.right_client == b.right_client and a.right_clock < Span.right_end(b) and
      b.right_clock < Span.right_end(a)
  end

  defp same_line?(a, b) do
    a.left_client == b.left_client and a.right_client == b.right_client and
      a.right_clock - a.left_clock == b.right_clock - b.left_clock
  end

  # Spans on the same mapping line that overlap or touch collapse into one, so
  # an exact duplicate extension is idempotent (§17).
  defp merge_lines(spans) do
    spans
    |> Enum.group_by(fn s -> {s.left_client, s.right_client, s.right_clock - s.left_clock} end)
    |> Enum.flat_map(fn {_line, group} -> merge_group(group) end)
    |> Enum.sort_by(&Span.sort_key/1)
  end

  defp merge_group(group) do
    group
    |> Enum.sort_by(& &1.left_clock)
    |> Enum.reduce([], fn span, acc ->
      case acc do
        [prev | rest] when span.left_clock <= prev.left_clock + prev.length ->
          new_end = max(Span.left_end(prev), Span.left_end(span))
          [%Span{prev | length: new_end - prev.left_clock} | rest]

        _ ->
          [span | acc]
      end
    end)
    |> Enum.reverse()
  end

  @doc "Portable wire value. Spec §8.6."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = bridge) do
    %{
      "version" => @format_version,
      "left_epoch" => bridge.left_epoch,
      "right_epoch" => bridge.right_epoch,
      "basis" => Basis.to_map(bridge.basis),
      "correspondence" => Derivation.to_map(bridge.correspondence)["spans"],
      "receipts" => Enum.map(bridge.receipts, &Receipt.to_map/1)
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(
        %{
          "version" => @format_version,
          "left_epoch" => left_epoch,
          "right_epoch" => right_epoch,
          "basis" => basis_map,
          "correspondence" => spans
        } = map
      ) do
    with {:ok, basis} <- decode(Basis.from_map(basis_map), :basis),
         {:ok, receipts} <- decode_receipts(Map.get(map, "receipts", [])),
         {:ok, derivation} <- Derivation.from_map(%{"version" => 1, "spans" => spans}),
         :ok <- Basis.validate(basis),
         :ok <- validate_epoch_ref(left_epoch, :left_epoch),
         :ok <- validate_epoch_ref(right_epoch, :right_epoch),
         :ok <- reject_equal_endpoints(left_epoch, right_epoch),
         {:ok, normalized} <- Derivation.normalize(derivation) do
      {:ok,
       %__MODULE__{
         format_version: @format_version,
         left_epoch: left_epoch,
         right_epoch: right_epoch,
         correspondence: normalized,
         basis: basis,
         receipts: receipts
       }}
    end
  end

  def from_map(_), do: {:error, Error.new(:invalid_derivation, :bridge)}

  defp decode_receipts(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn raw, {:ok, acc} ->
      case Receipt.from_map(raw) do
        {:ok, receipt} -> {:cont, {:ok, acc ++ [receipt]}}
        _ -> {:halt, {:error, Error.new(:invalid_derivation, :bridge, path: [:receipts])}}
      end
    end)
  end

  defp decode_receipts(_),
    do: {:error, Error.new(:invalid_derivation, :bridge, path: [:receipts])}

  defp decode({:ok, value}, _field), do: {:ok, value}
  defp decode(_, field), do: {:error, Error.new(:invalid_derivation, :bridge, path: [field])}
end
