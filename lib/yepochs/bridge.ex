defmodule Yepochs.Bridge do
  @moduledoc """
  A derivation with its source and target Yepoch references attached.
  Spec §6.6, §8.3, §11–§14, §17.

      source Yepoch --snapshot/derivation--> target Yepoch

  The stored spans still point from target coordinates back to source
  coordinates; attaching endpoint labels changes no span (§11).
  """

  alias Yepochs.Algorithm
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Span

  @format_version 1
  @max_epoch_ref_bytes 1024

  @enforce_keys [:format_version, :source_epoch, :target_epoch, :derivation, :producer]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          format_version: pos_integer(),
          source_epoch: String.t(),
          target_epoch: String.t(),
          derivation: Derivation.t(),
          producer: Algorithm.t()
        }

  @type item_ref :: Span.item_ref()

  @doc """
  Spec §11. Validates both epoch references, validates and normalizes the
  derivation, and rejects equal endpoints.
  """
  @spec attach(Derivation.t(), String.t(), String.t(), Algorithm.t()) ::
          {:ok, t()} | {:error, Error.t()}
  def attach(%Derivation{} = derivation, source_epoch, target_epoch, %Algorithm{} = producer) do
    with :ok <- validate_epoch_ref(source_epoch, :source_epoch),
         :ok <- validate_epoch_ref(target_epoch, :target_epoch),
         :ok <- reject_equal_endpoints(source_epoch, target_epoch),
         {:ok, normalized} <- Derivation.normalize(derivation) do
      {:ok,
       %__MODULE__{
         format_version: @format_version,
         source_epoch: source_epoch,
         target_epoch: target_epoch,
         derivation: normalized,
         producer: producer
       }}
    end
  end

  # §6.3: an opaque, canonical UTF-8 string. Not required to be a UUID, CID,
  # hash, or Commonplace commit ID; compared byte-for-byte.
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
  Stored provenance direction: target -> source. Spec §12.

  Resolves a reference to any clock inside a span, not only the first clock of
  an encoded Yjs item, and never falls back to the same numeric coordinate.
  """
  @spec source_ref(t(), item_ref()) :: {:ok, item_ref()} | :unmapped
  def source_ref(%__MODULE__{} = bridge, {client, clock}) do
    lookup(bridge.derivation.spans, client, clock, :target)
  end

  @doc "Translation direction: source -> target. Spec §12."
  @spec target_ref(t(), item_ref()) :: {:ok, item_ref()} | :unmapped
  def target_ref(%__MODULE__{} = bridge, {client, clock}) do
    lookup(bridge.derivation.spans, client, clock, :source)
  end

  defp lookup(spans, client, clock, from) do
    {from_client, from_clock, to_client, to_clock} =
      case from do
        :target -> {:target_client, :target_clock, :source_client, :source_clock}
        :source -> {:source_client, :source_clock, :target_client, :target_clock}
      end

    Enum.find_value(spans, :unmapped, fn span ->
      base = Map.fetch!(span, from_clock)

      if Map.fetch!(span, from_client) == client and clock >= base and clock < base + span.length do
        {:ok, {Map.fetch!(span, to_client), Map.fetch!(span, to_clock) + (clock - base)}}
      end
    end)
  end

  @doc "Spec §13. Swaps the endpoint references and every span coordinate, then normalizes."
  @spec invert(t()) :: {:ok, t()} | {:error, Error.t()}
  def invert(%__MODULE__{} = bridge) do
    with {:ok, inverted} <- Derivation.invert(bridge.derivation) do
      {:ok,
       %__MODULE__{
         bridge
         | source_epoch: bridge.target_epoch,
           target_epoch: bridge.source_epoch,
           derivation: inverted
       }}
    end
  end

  @doc """
  Spec §14. Composes `A --ab--> B --bc--> C` into `A --ac--> C`, calculating the
  stored mapping in provenance direction `C -> B -> A`.

  The result may be smaller than either input, because each bridge is partial.
  Missing coverage is reported later by preflight; composition never invents it.
  """
  @spec compose([t()]) :: {:ok, t()} | {:error, Error.t()}
  def compose([]), do: {:error, Error.new(:bridge_endpoint_mismatch, :bridge, path: [:path])}
  def compose([%__MODULE__{} = only]), do: {:ok, only}

  def compose([%__MODULE__{} = first | rest] = bridges) when is_list(bridges) do
    Enum.reduce_while(rest, {:ok, first}, fn next, {:ok, acc} ->
      case compose_pair(acc, next) do
        {:ok, composed} -> {:cont, {:ok, composed}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp compose_pair(%__MODULE__{} = ab, %__MODULE__{} = bc) do
    if ab.target_epoch != bc.source_epoch do
      {:error,
       Error.new(:bridge_endpoint_mismatch, :bridge,
         details: %{expected_source: ab.target_epoch, got_source: bc.source_epoch}
       )}
    else
      spans =
        for bc_span <- bc.derivation.spans,
            ab_span <- ab.derivation.spans,
            bc_span.source_client == ab_span.target_client,
            overlap = intersect(bc_span, ab_span),
            overlap != nil,
            do: overlap

      with {:ok, derivation} <- Derivation.new(spans),
           {:ok, normalized} <- Derivation.normalize(derivation) do
        {:ok,
         %__MODULE__{
           format_version: @format_version,
           source_epoch: ab.source_epoch,
           target_epoch: bc.target_epoch,
           derivation: normalized,
           producer: Algorithm.compose()
         }}
      end
    end
  end

  # Intersect the two spans over their shared intermediate (B) clock range,
  # then re-express the overlap as C -> A.
  defp intersect(bc_span, ab_span) do
    lo = max(bc_span.source_clock, ab_span.target_clock)
    hi = min(Span.source_end(bc_span), Span.target_end(ab_span))

    if lo < hi do
      %Span{
        target_client: bc_span.target_client,
        target_clock: bc_span.target_clock + (lo - bc_span.source_clock),
        source_client: ab_span.source_client,
        source_clock: ab_span.source_clock + (lo - ab_span.target_clock),
        length: hi - lo
      }
    end
  end

  @doc """
  Spec §17. Adds admitted carried-identity mappings to a bridge.

  This is an admission record, not merely an optimization: the caller must
  persist the extension, or reconstruct it from accepted translated commits,
  before translating a later dependent update.
  """
  @spec extend(t(), Derivation.t()) :: {:ok, t()} | {:error, Error.t()}
  def extend(%__MODULE__{} = bridge, %Derivation{} = addition) do
    with :ok <- Derivation.validate(addition),
         :ok <- check_extension_consistency(bridge.derivation.spans, addition.spans),
         {:ok, derivation} <-
           Derivation.new(merge_lines(bridge.derivation.spans ++ addition.spans)),
         {:ok, normalized} <- Derivation.normalize(derivation) do
      {:ok, %__MODULE__{bridge | derivation: normalized}}
    end
  end

  # An overlap is admissible only when both spans lie on the same mapping line —
  # same client pair, same clock delta. Anything else would give one side two
  # meanings.
  defp check_extension_consistency(existing, additions) do
    Enum.reduce_while(additions, :ok, fn add, :ok ->
      conflict =
        Enum.find(existing, fn old ->
          (overlaps?(old, add, :target) or overlaps?(old, add, :source)) and
            not same_line?(old, add)
        end)

      if conflict do
        {:halt, {:error, Error.new(:invalid_derivation, :bridge, path: [:extension])}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp overlaps?(a, b, :target) do
    a.target_client == b.target_client and
      a.target_clock < Span.target_end(b) and b.target_clock < Span.target_end(a)
  end

  defp overlaps?(a, b, :source) do
    a.source_client == b.source_client and
      a.source_clock < Span.source_end(b) and b.source_clock < Span.source_end(a)
  end

  defp same_line?(a, b) do
    a.target_client == b.target_client and a.source_client == b.source_client and
      a.source_clock - a.target_clock == b.source_clock - b.target_clock
  end

  # Spans on the same mapping line that overlap or touch collapse into one, so
  # an exact duplicate extension is idempotent (§17).
  defp merge_lines(spans) do
    spans
    |> Enum.group_by(fn s -> {s.target_client, s.source_client, s.source_clock - s.target_clock} end)
    |> Enum.flat_map(fn {_line, group} -> merge_group(group) end)
    |> Enum.sort_by(&Span.sort_key/1)
  end

  defp merge_group(group) do
    group
    |> Enum.sort_by(& &1.target_clock)
    |> Enum.reduce([], fn span, acc ->
      case acc do
        [prev | rest] when span.target_clock <= prev.target_clock + prev.length ->
          new_end = max(Span.target_end(prev), Span.target_end(span))
          [%Span{prev | length: new_end - prev.target_clock} | rest]

        _ ->
          [span | acc]
      end
    end)
    |> Enum.reverse()
  end

  @doc "Portable wire value. Spec §8.5."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = bridge) do
    bridge.derivation
    |> Derivation.to_map()
    |> Map.merge(%{
      "version" => @format_version,
      "source_epoch" => bridge.source_epoch,
      "target_epoch" => bridge.target_epoch,
      "producer" => Algorithm.to_map(bridge.producer)
    })
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(%{
        "version" => @format_version,
        "source_epoch" => source_epoch,
        "target_epoch" => target_epoch,
        "producer" => producer_map,
        "spans" => spans
      }) do
    with {:ok, producer} <- algorithm_from_map(producer_map),
         {:ok, derivation} <- Derivation.from_map(%{"version" => 1, "spans" => spans}) do
      attach(derivation, source_epoch, target_epoch, producer)
    end
  end

  def from_map(_), do: {:error, Error.new(:invalid_derivation, :bridge)}

  defp algorithm_from_map(map) do
    case Algorithm.from_map(map) do
      {:ok, algorithm} -> {:ok, algorithm}
      :error -> {:error, Error.new(:incompatible_algorithm, :bridge, path: [:producer])}
    end
  end
end
