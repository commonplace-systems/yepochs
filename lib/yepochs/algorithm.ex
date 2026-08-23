defmodule Yepochs.Algorithm do
  @moduledoc """
  A durable semantic identifier for the algorithm that produced an artifact.
  Spec §8.4, §21.

  Algorithm versions are independent of the Hex package version. Any change that
  can alter accepted input, rejected input, output bytes, mapping semantics, or
  rebase results requires a new algorithm version — including bug fixes, unless
  the previous behaviour could never have produced a successful valid artifact.
  """

  @enforce_keys [:id, :version]
  defstruct @enforce_keys

  @type t :: %__MODULE__{id: String.t(), version: pos_integer()}

  @doc "Compatibility extraction of the experimental Commonplace snapshotter."
  def snapshot, do: %__MODULE__{id: "yepochs.snapshot", version: 2}
  @doc "Strict identity translation."
  def translate, do: %__MODULE__{id: "yepochs.translate", version: 1}
  @doc "Bidirectional crossing strategy and result contract."
  def cross, do: %__MODULE__{id: "yepochs.cross", version: 1}
  @doc "Positional re-authoring fallback."
  def rebase, do: %__MODULE__{id: "yepochs.rebase", version: 1}
  @doc "Composition of compatible bridge mappings."
  def compose, do: %__MODULE__{id: "yepochs.compose", version: 1}
  @doc "Addition of admitted carried-identity mappings."
  def extend, do: %__MODULE__{id: "yepochs.extend", version: 1}

  @doc "Every algorithm version this build supports. Spec §21 requires this be exposed."
  @spec supported() :: [t()]
  def supported, do: [snapshot(), translate(), cross(), rebase(), compose(), extend()]

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = a), do: %{"id" => a.id, "version" => a.version}

  @spec from_map(map()) :: {:ok, t()} | :error
  def from_map(%{"id" => id, "version" => v})
      when is_binary(id) and is_integer(v) and v > 0 do
    {:ok, %__MODULE__{id: id, version: v}}
  end

  def from_map(_), do: :error
end
