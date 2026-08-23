defmodule Yepochs.Bridge.Basis do
  @moduledoc """
  How a bridge's initial correspondence was established. Spec r2 §8.3.

  A `:snapshot` basis records which endpoint was re-authored from the other. A
  `:composition` or `:explicit` basis makes no such claim. ⭐ **This metadata
  does not constrain the direction of later crossings** — it is provenance, not
  permission.
  """

  alias Yepochs.Algorithm
  alias Yepochs.Error

  @enforce_keys [:kind, :producer]
  defstruct [:kind, :producer, :origin, :derived]

  @type side :: :left | :right
  @type kind :: :snapshot | :composition | :explicit

  @type t :: %__MODULE__{
          kind: kind(),
          producer: Algorithm.t(),
          origin: side() | nil,
          derived: side() | nil
        }

  @doc """
  For `:snapshot`, `origin` and `derived` MUST name opposite sides. For a
  composed or explicitly asserted bridge they MUST be null, because neither
  endpoint is claimed to have been produced from the other.
  """
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{kind: :snapshot, origin: o, derived: d})
      when {o, d} in [{:left, :right}, {:right, :left}],
      do: :ok

  def validate(%__MODULE__{kind: kind, origin: nil, derived: nil})
      when kind in [:composition, :explicit],
      do: :ok

  def validate(%__MODULE__{}),
    do: {:error, Error.new(:invalid_derivation, :bridge, path: [:basis])}

  @doc "Exchanges the origin/derived side labels. Used when a bridge is reoriented (§13)."
  @spec flip(t()) :: t()
  def flip(%__MODULE__{} = b),
    do: %__MODULE__{b | origin: other(b.origin), derived: other(b.derived)}

  defp other(:left), do: :right
  defp other(:right), do: :left
  defp other(nil), do: nil

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = b) do
    %{
      "kind" => Atom.to_string(b.kind),
      "origin" => side_to_string(b.origin),
      "derived" => side_to_string(b.derived),
      "producer" => Algorithm.to_map(b.producer)
    }
  end

  defp side_to_string(nil), do: nil
  defp side_to_string(side), do: Atom.to_string(side)

  # Wire strings are matched against a fixed whitelist. Never String.to_atom/1:
  # §23 forbids creating atoms from wire data.
  @spec from_map(map()) :: {:ok, t()} | :error
  def from_map(%{"kind" => kind, "producer" => producer} = map) do
    with {:ok, kind} <-
           fetch(
             %{"snapshot" => :snapshot, "composition" => :composition, "explicit" => :explicit},
             kind
           ),
         {:ok, origin} <- fetch_side(Map.get(map, "origin")),
         {:ok, derived} <- fetch_side(Map.get(map, "derived")),
         {:ok, producer} <- Algorithm.from_map(producer) do
      {:ok, %__MODULE__{kind: kind, producer: producer, origin: origin, derived: derived}}
    end
  end

  def from_map(_), do: :error

  defp fetch_side(nil), do: {:ok, nil}
  defp fetch_side(v), do: fetch(%{"left" => :left, "right" => :right}, v)

  defp fetch(table, key) do
    case Map.fetch(table, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end
end
