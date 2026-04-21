defmodule AntiAgents.MixProject do
  use Mix.Project

  def project do
    [
      app: :anti_agents,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      preferred_cli_env: preferred_cli_env(),
      docs: docs(),
      package: package(),
      dialyzer: dialyzer()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:codex_sdk, "~> 0.16"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "main",
      source_url: "https://github.com/nshkrdotcom/anti_agents",
      homepage_url: "https://github.com/nshkrdotcom/anti_agents",
      logo: "assets/anti_agents.svg",
      extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md"] ++ Path.wildcard("docs/*.md"),
      assets: %{"assets" => "assets"}
    ]
  end

  defp package do
    [
      name: "anti_agents",
      description:
        "SSoT frontier prompting, burst branching, and novelty scoring for Codex-backed diversity experiments.",
      files: [
        "lib",
        "priv",
        "assets",
        "docs",
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE",
        "mix.exs"
      ],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/nshkrdotcom/anti_agents",
        "arXiv" => "https://arxiv.org/abs/2510.21150"
      }
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:ex_unit, :mix]
    ]
  end

  defp aliases do
    [
      verify: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test",
        "dialyzer",
        "anti_agents.benchmark --fields priv/benchmarks/fields_v1.json --dry-run"
      ]
    ]
  end

  defp preferred_cli_env do
    [
      verify: :test
    ]
  end
end
