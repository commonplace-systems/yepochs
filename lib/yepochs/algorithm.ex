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

  @doc """
  Deterministic snapshotting with **span-complete** derivations.

  ⛔ **Version 3, not 2 — and the distinction is durable, not cosmetic.** Version
  2 is the experimental *item-start* derivation algorithm, which covers only the
  first clock of each replayed item (measured: **1 of 8** on a document written
  as eight one-character inserts). This build emits clock **spans** covering
  every emitted clock, which is different mapping semantics.

  Span-complete derivations change persisted snapshot metadata and therefore
  change content-addressed commit IDs. Assigning them to version 2 would give
  one durable version tag two meanings — precisely the silent aliasing a version
  tag exists to prevent.
  """
  def snapshot, do: %__MODULE__{id: "yepochs.snapshot", version: 3}

  @doc """
  The legacy item-start derivation algorithm. **Recognised, not produced.**

  This build cannot emit version 2, so requesting it returns
  `:incompatible_algorithm` rather than silently serving version 3's different
  semantics. It is named here so a caller reading a v2 artifact can identify it,
  and so the version number is never reused.
  """
  def snapshot_v2, do: %__MODULE__{id: "yepochs.snapshot", version: 2}
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

  @doc """
  Algorithms this build can identify but MUST NOT produce. Spec ruling 8.4.

  Requesting one is `:incompatible_algorithm`: a durable caller replaying a v2
  artifact needs to be told this build cannot reproduce it, not handed v3 bytes
  under a v2 tag.
  """
  @spec legacy() :: [t()]
  def legacy, do: [snapshot_v2()]

  @doc """
  Whether this build implements exactly this algorithm and version. Spec §21.

  ⛔ Version equality is exact in **both** directions. A newer build must not
  serve a request for an older version either: an old durable artifact replayed
  under newer rules would produce different bytes under the same version tag,
  which is the silent aliasing the tag exists to prevent.
  """
  @spec supports?(t()) :: boolean()
  def supports?(%__MODULE__{} = requested), do: requested in supported()

  @doc """
  Resolves a caller's requested algorithm against `default`, or refuses.

  §21: a durable caller MUST select a version explicitly and the library MUST
  NOT silently substitute a newer one.
  """
  @spec resolve(keyword(), t(), atom()) :: {:ok, t()} | {:error, Yepochs.Error.t()}
  def resolve(opts, %__MODULE__{} = default, phase) do
    case Keyword.get(opts, :algorithm) do
      nil ->
        {:ok, default}

      %__MODULE__{id: id} = requested when id == :erlang.map_get(:id, default) ->
        if supports?(requested),
          do: {:ok, requested},
          else: incompatible(requested, phase)

      other ->
        incompatible(other, phase)
    end
  end

  defp incompatible(requested, phase) do
    {:error,
     Yepochs.Error.new(:incompatible_algorithm, phase,
       details: %{requested: requested, supported: supported()}
     )}
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = a), do: %{"id" => a.id, "version" => a.version}

  @spec from_map(map()) :: {:ok, t()} | :error
  def from_map(%{"id" => id, "version" => v})
      when is_binary(id) and is_integer(v) and v > 0 do
    {:ok, %__MODULE__{id: id, version: v}}
  end

  def from_map(_), do: :error
end
