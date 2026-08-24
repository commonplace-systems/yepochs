defmodule Yepochs.EpochToken do
  @moduledoc """
  Deterministic epoch-token minting as specified in design note 0010.
  """

  alias Yepochs.Algorithm
  alias Yepochs.Error

  @domain "yepochs.epoch-token.v1"
  @max_ref_bytes 1024

  @spec mint([String.t()], [String.t()], Algorithm.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def mint(parent_ids, source_epochs, %Algorithm{} = algorithm) do
    with :ok <- validate_refs(parent_ids, :parent_ids),
         :ok <- validate_refs(source_epochs, :source_epochs) do
      payload = [
        @domain,
        framed_list(normalize(parent_ids)),
        framed_list(normalize(source_epochs)),
        framed(algorithm.id),
        <<algorithm.version::unsigned-big-32>>
      ]

      token = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
      {:ok, token}
    end
  end

  defp validate_refs(refs, field) when is_list(refs) do
    refs
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {ref, index}, :ok ->
      if valid_ref?(ref) do
        {:cont, :ok}
      else
        {:halt, invalid_ref(field, index)}
      end
    end)
  end

  defp validate_refs(_, field), do: invalid_ref(field, 0)

  defp valid_ref?(ref) when is_binary(ref) do
    byte_size(ref) > 0 and byte_size(ref) <= @max_ref_bytes and String.valid?(ref)
  end

  defp valid_ref?(_), do: false

  defp invalid_ref(field, index) do
    {:error, Error.new(:invalid_epoch_ref, :snapshot, path: [field, index])}
  end

  defp normalize(items), do: items |> Enum.uniq() |> Enum.sort()

  defp framed_list(items), do: [<<length(items)::unsigned-big-32>> | Enum.map(items, &framed/1)]

  defp framed(binary), do: [<<byte_size(binary)::unsigned-big-32>>, binary]
end
