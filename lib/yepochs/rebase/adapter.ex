defmodule Yepochs.Rebase.Adapter do
  @moduledoc """
  The extension point for application-specific positional re-authoring.
  Spec r2 §19.2.

  The built-in dispatch covers the three planes Yjs itself defines — text, map
  and array. An application whose schema carries meaning those planes cannot
  express (an ordered set, a CRDT counter, a domain-specific merge) supplies an
  adapter instead of patching this library.

  ⛔ **`yepochs` MUST NOT depend on Commonplace document modules** (§19.2, §2).
  This behaviour is what keeps that true while still letting Commonplace — or
  anyone — bring their own semantics.

  Adapters are consulted **before** the built-in planes and are tried in the
  order given, so an adapter can deliberately override a built-in for a type it
  owns. An adapter's error is returned as-is rather than falling through: it has
  claimed the type, so silently substituting a generic diff would discard the
  very knowledge the adapter exists to apply.

  ## Determinism

  §19.3: deterministic re-authoring requires an explicit author id, algorithm
  version, and **adapter set**. ⚠️ An adapter that consults wall-clock time,
  randomness, or process state makes its caller's output
  non-content-addressable — the library cannot detect that and does not try.
  """

  alias Yelixer.Doc
  alias Yepochs.Error

  @typedoc "A named top-level type in the document."
  @type type_name :: String.t()

  @doc """
  Whether this adapter owns `type_name` for this pair of states.

  Both documents are supplied because ownership can depend on shape as well as
  name — a type may hold an application schema in one state and be absent in the
  other.
  """
  @callback handles?(before :: Doc.t(), edited :: Doc.t(), type_name()) :: boolean()

  @doc """
  Re-authors this type's change from `before`→`edited` onto `destination`.

  Returns the updated destination document and whether anything changed;
  `false` means the effect was already satisfied there, which becomes an
  absorbed crossing.

  ⛔ Must not guess. When the destination has diverged from what the edit
  expects, return `:rebase_conflict` rather than placing the change somewhere
  plausible.
  """
  @callback reauthor(
              before :: Doc.t(),
              edited :: Doc.t(),
              destination :: Doc.t(),
              type_name(),
              opts :: keyword()
            ) :: {:ok, Doc.t(), changed? :: boolean()} | {:error, Error.t()}
end
