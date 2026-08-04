defmodule AshOnetime.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/baselabs/ash_onetime"

  def project do
    [
      app: :ash_onetime,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:ecto_sql]],
      test_paths: ["test"]
    ]
  end

  def application do
    [extra_applications: [:crypto, :logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.29"},
      {:ash_postgres, "~> 2.11"},
      {:spark, "~> 2.7"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.4"},
      {:plug, "~> 1.20", optional: true},
      {:oban, "~> 2.23", optional: true},
      {:igniter, "~> 0.8", optional: true},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.4"}
    ]
  end

  defp description do
    "An Ash extension for explicit idempotency and one-time nonce semantics"
  end

  defp package do
    [
      files: [
        "lib",
        "documentation",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "LICENSE",
        "usage-rules.md"
      ],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Russ Palermo"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "documentation/getting-started.md", "CHANGELOG.md"]
    ]
  end
end
