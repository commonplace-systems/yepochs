defmodule Yepochs do
  @moduledoc """
  Yjs identity-space algebra: Yepochs, deterministic snapshots, derivations,
  bilateral bridges, crossings, strict translation, and positional re-authoring.

  Spec: `docs/proposals/2026-08-23-yepochs-spec-r2.md` (sha256 `8765bb15…`).
  ⚠️ Two revisions exist and are indistinguishable by header — tell them apart
  by hash.

  This library owns Yjs identity-space algebra. It does **not** own Commonplace
  logs, Merkle commits, branches, signatures, admission policy, or document
  processes, and it depends on Yelixer and ordinary utility libraries only.
  """

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Crossing
  alias Yepochs.Crossing.Receipt
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Preflight
  alias Yepochs.Rebase
  alias Yepochs.Snapshotter
  alias Yepochs.Span
  alias Yepochs.Translator

  # A strict failure in this set is internal control flow, not a crossing
  # result: it selects re-authoring (§15.3, §16, §27.4).
  @reauthorable [
    :missing_anchor,
    :missing_operation_target,
    :target_identity_collision,
    :unsupported_translation_feature
  ]

  @doc "Deterministic re-authoring of a document's observable state. Spec §10."
  defdelegate snapshot(doc, opts \\ []), to: Snapshotter

  @doc "Strict-translation preflight. Spec §16."
  defdelegate preflight(update, bridge, direction, opts \\ []), to: Preflight, as: :run

  @doc "Strict, identity-preserving translation. Spec §15.3."
  defdelegate translate(update, bridge, direction, opts \\ []), to: Translator

  @doc """
  Strict translation across a composed path. Spec §18.

  ⚠️ **This is the strict-only algebra, not the Bridge contract.** A live tree
  normally propagates an edit **one edge at a time**, because each hop lets the
  intermediate endpoints learn the edit and lets every bilateral relationship
  evolve. `translate_path/3` composes the path and translates once instead — it
  does **not** update the constituent bridges, and it does not re-author.

  ⇒ If it fails, the caller must cross the edit edge by edge, or call `cross/5`
  against a real bridge joining the final endpoint states.

  The update is understood at the first bridge's **left** endpoint; path
  discovery and the choice between competing paths belong to the caller.
  """
  @spec translate_path(binary(), [Bridge.t()], keyword()) ::
          {:ok, Yepochs.Translation.t()} | {:error, Error.t()}
  def translate_path(update, bridges, opts \\ [])

  def translate_path(_update, [], _opts),
    do: {:error, Error.new(:bridge_endpoint_mismatch, :translate, path: [:path])}

  def translate_path(update, bridges, opts) when is_list(bridges) do
    # Compose first, then decode and translate ONCE -- §18 forbids re-decoding
    # and re-encoding at every hop.
    with {:ok, composed} <- Bridge.compose(bridges) do
      Translator.translate(update, composed, :left, opts)
    end
  end

  @doc "Positional re-authoring. Spec §19."
  defdelegate rebase(before, edited, target, opts \\ []), to: Rebase

  @doc """
  Cross one edit between a bridge's endpoints. Spec §15.1.

  ⭐ **For a structurally valid edit over the supported data model this returns
  an update applicable to the destination, in either direction.** Missing
  coordinate coverage and strict identity collisions are *not* terminal errors:
  they select positional re-authoring.

  Required options:

    * `:from` — `:left` or `:right`, the endpoint the edit was authored at
    * `:author` — destination author id, for possible re-authoring
    * `:receipt_ref` — the caller's opaque edit reference; Yepochs neither
      interprets nor mints it

  ⛔ The caller MUST apply or durably admit the returned update **before**
  applying its bridge delta (§15.2).
  """
  @spec cross(Bridge.t(), binary(), Doc.t(), Doc.t(), keyword()) ::
          {:ok, Crossing.t()} | {:error, Error.t()}
  def cross(%Bridge{} = bridge, update, %Doc{} = source_before, %Doc{} = destination, opts) do
    with {:ok, from} <- fetch_direction(opts),
         {:ok, ref} <- fetch_receipt_ref(opts),
         :ok <- require_author(opts) do
      attempt_strict(bridge, update, source_before, destination, from, ref, opts)
    end
  end

  defp fetch_direction(opts) do
    case Keyword.get(opts, :from) do
      side when side in [:left, :right] -> {:ok, side}
      _ -> {:error, Error.new(:invalid_rebase_input, :cross, path: [:from])}
    end
  end

  defp fetch_receipt_ref(opts) do
    case Keyword.get(opts, :receipt_ref) do
      ref when is_binary(ref) and byte_size(ref) > 0 -> {:ok, ref}
      _ -> {:error, Error.new(:invalid_rebase_input, :cross, path: [:receipt_ref])}
    end
  end

  defp require_author(opts) do
    case Keyword.get(opts, :author) do
      id when is_integer(id) and id >= 0 -> :ok
      _ -> {:error, Error.new(:invalid_rebase_input, :cross, path: [:author])}
    end
  end

  defp attempt_strict(bridge, update, source_before, destination, from, ref, opts) do
    case Translator.translate(update, bridge, from, opts) do
      {:ok, translation} ->
        {:ok, carried} = orient(translation.carried, from)

        build(bridge, from, ref, translation.update, :translated, :applied, carried)

      {:error, %Error{code: code}} when code in @reauthorable ->
        reauthor(bridge, update, source_before, destination, from, ref, opts)

      {:error, _} = error ->
        error
    end
  end

  defp reauthor(bridge, update, source_before, destination, from, ref, opts) do
    with {:ok, edited} <- apply_privately(source_before, update),
         {:ok, result} <- Rebase.rebase(source_before, edited, destination, opts),
         {:ok, empty} <- Derivation.new([]) do
      # §17: a re-authored delta adds non-identity spans wherever the adapter can
      # prove a correspondence. The 0.1 text adapter proves none -- it re-authors
      # by observable diff and cannot say which destination item answers which
      # source item -- so the delta carries its receipt alone, which §17 requires
      # even then.
      mode = if result.outcome == :absorbed, do: :absorbed, else: :reauthored
      build(bridge, from, ref, result.update, mode, result.outcome, empty)
    end
  end

  # §15.1: the function applies the source update to a PRIVATE copy of
  # source_before when it needs the edited state.
  defp apply_privately(%Doc{} = source_before, update) do
    case Encoding.apply_update(source_before, update) do
      {:ok, edited} -> {:ok, edited}
      _ -> {:error, Error.new(:malformed_update, :cross)}
    end
  end

  # `carried` arrives in LOCAL orientation (left = authored, right =
  # destination). The delta's spans must be in the bridge's orientation.
  defp orient(carried, :left), do: {:ok, carried}

  defp orient(carried, :right) do
    carried.spans
    |> Enum.map(&Span.flip/1)
    |> Derivation.new()
    |> case do
      {:ok, d} -> Derivation.normalize(d)
      other -> other
    end
  end

  defp build(bridge, from, ref, update, mode, outcome, correspondence) do
    to = if from == :left, do: :right, else: :left

    {:ok,
     %Crossing{
       from_epoch: endpoint(bridge, from),
       to_epoch: endpoint(bridge, to),
       update: update,
       mode: mode,
       outcome: outcome,
       bridge_delta: %Bridge.Delta{
         correspondence: correspondence,
         receipt: %Receipt{
           ref: ref,
           from: from,
           to: to,
           mode: mode,
           outcome: outcome,
           algorithm: Algorithm.cross()
         }
       },
       algorithm: Algorithm.cross()
     }}
  end

  defp endpoint(%Bridge{left_epoch: e}, :left), do: e
  defp endpoint(%Bridge{right_epoch: e}, :right), do: e
end
