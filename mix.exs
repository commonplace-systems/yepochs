defmodule Yepochs.MixProject do
  use Mix.Project

  def project do
    [
      app: :yepochs,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "Yjs identity-space algebra: Yepochs, derivations, bridges, and strict update translation.",
      package: package(),
      source_url: "https://github.com/commonplace-systems/yepochs"
    ]
  end

  # No runtime process, registry, supervisor, storage adapter, or network
  # client. Spec §29.
  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/commonplace-systems/yepochs"},
      files: ~w(lib mix.exs README.md)
    ]
  end

  # Tier 0 (the identity-space algebra) depends on nothing; Yelixer enters with
  # the update codec at Tier 1. Spec §2: yepochs MUST depend on Yelixer and
  # ordinary utility libraries only, and MUST NOT depend on any Commonplace
  # package. See docs/design/0001-build-order-and-gate.md.
  #
  # Pinned to the same ref `commonplace` uses, because §10.4 and §15.10
  # determinism are stated against a PINNED codec version -- an unpinned codec
  # would make "the same bytes" a claim about whatever was fetched that day.
  defp deps do
    [
      {:yelixer, git: "https://github.com/commonplace-systems/yelixer.git", ref: "bc35a0e9"},
      {:stream_data, "~> 1.0", only: [:test]}
    ]
  end
end
