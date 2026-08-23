defmodule Yepochs.Crossing.Receipt do
  @moduledoc """
  Evidence that one edit crossed a bridge. Spec r2 §8.4.

  The `ref` is an **opaque** crossing or source-edit reference supplied by the
  caller — Commonplace normally uses a Merkle commit or operation ID.
  ⭐ **Yepochs does not interpret or mint it.**

  A receipt is mandatory for every successful crossing, including an absorbed
  one whose correspondence is empty (§17).
  """

  alias Yepochs.Algorithm

  @enforce_keys [:ref, :from, :to, :mode, :outcome, :algorithm]
  defstruct @enforce_keys

  @type side :: :left | :right
  @type mode :: :translated | :reauthored | :absorbed
  @type outcome :: :applied | :absorbed

  @type t :: %__MODULE__{
          ref: String.t(),
          from: side(),
          to: side(),
          mode: mode(),
          outcome: outcome(),
          algorithm: Algorithm.t()
        }

  @doc "Exchanges the from/to sides. Used when a bridge is reoriented (§13)."
  @spec flip(t()) :: t()
  def flip(%__MODULE__{} = r), do: %__MODULE__{r | from: other(r.from), to: other(r.to)}

  defp other(:left), do: :right
  defp other(:right), do: :left

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = r) do
    %{
      "ref" => r.ref,
      "from" => Atom.to_string(r.from),
      "to" => Atom.to_string(r.to),
      "mode" => Atom.to_string(r.mode),
      "outcome" => Atom.to_string(r.outcome),
      "algorithm" => Algorithm.to_map(r.algorithm)
    }
  end

  @sides %{"left" => :left, "right" => :right}
  @modes %{"translated" => :translated, "reauthored" => :reauthored, "absorbed" => :absorbed}
  @outcomes %{"applied" => :applied, "absorbed" => :absorbed}

  @spec from_map(map()) :: {:ok, t()} | :error
  def from_map(%{
        "ref" => ref,
        "from" => from,
        "to" => to,
        "mode" => mode,
        "outcome" => outcome,
        "algorithm" => algorithm
      })
      when is_binary(ref) do
    with {:ok, from} <- Map.fetch(@sides, from),
         {:ok, to} <- Map.fetch(@sides, to),
         {:ok, mode} <- Map.fetch(@modes, mode),
         {:ok, outcome} <- Map.fetch(@outcomes, outcome),
         {:ok, algorithm} <- Algorithm.from_map(algorithm) do
      {:ok,
       %__MODULE__{
         ref: ref,
         from: from,
         to: to,
         mode: mode,
         outcome: outcome,
         algorithm: algorithm
       }}
    end
  end

  def from_map(_), do: :error
end
