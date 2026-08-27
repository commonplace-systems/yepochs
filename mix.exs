defmodule Yepochs.MixProject do
  use Mix.Project

  def project do
    [
      app: :yepochs,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: [
        # ⛔ NO SINGLE ENV RUNS ALL FOUR. `test` refuses to start outside :test;
        # `dialyzer` does not EXIST outside :dev, because dialyxir is
        # `only: [:dev]`. Forcing the alias to either env silently drops a
        # stage — measured: under :test the alias died with
        # `The task "dialyzer" could not be found` AFTER the suite had passed,
        # which reads like a flake rather than a missing stage.
        # ⇒ Run the first three in :test (see `def cli`) and shell out for
        # dialyzer with its own env.
        # ⭐ THE SHELL SELF-TESTS RUN FIRST AND COST NOTHING. They were written
        # 2026-08-27 and NOTHING RAN THEM -- the same defect as `mix check`
        # itself having been documented for days and never once executed. A
        # gate nobody invokes is a remembered rule with a citation.
        # ⚠️ A Mix alias does NOT short-circuit (measured, docs/design/0011):
        # a failing stage still runs the later ones, though the alias's rc is
        # preserved. These are placed first so their output is not buried.
        check: [
          "cmd bin/mutate.sh --self-test",
          "cmd bin/box-sample.sh --self-test",
          "format --check-formatted",
          "compile --warnings-as-errors",
          "test",
          "cmd MIX_ENV=dev mix dialyzer"
        ]
      ],
      deps: deps(),
      description:
        "Yjs identity-space algebra: Yepochs, derivations, bridges, and strict update translation.",
      package: package(),
      source_url: "https://github.com/commonplace-systems/yepochs",
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
      ]
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
  # ⛔ WITHOUT THIS, `mix check` DIES BEFORE ITS FIRST STAGE. The alias runs
  # `test`, which refuses to start in the :dev environment, so the whole alias
  # exits 1 having run NOTHING — not formatting, not compile, not dialyzer.
  # ⚠️ Measured 2026-08-27: the README had claimed for days that `mix check`
  # "runs the lot", and the alias had never once been executed. A documented
  # gate that has never been run is a remembered rule with a citation.
  def cli, do: [preferred_envs: [check: :test]]

  defp deps do
    [
      {:yelixer, git: "https://github.com/commonplace-systems/yelixer.git", ref: "bc35a0e9"},
      {:stream_data, "~> 1.0", only: [:test]},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end
end
