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

  # Tier 0 (the identity-space algebra) depends on nothing. Yelixer enters
  # only with the update codec at Tier 1. See docs/design/0001-build-order.md.
  defp deps do
    [
      {:stream_data, "~> 1.0", only: [:test]}
    ]
  end
end
