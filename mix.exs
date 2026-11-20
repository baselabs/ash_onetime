defmodule AshOnetime.MixProject do
  use Mix.Project

  @version "1.10.0"
  @source_url "https://github.com/baselabs/ash_onetime"

  def project do
    [
      app: :ash_onetime,
      version: @version,
      # Elixir requirement — the PUBLIC support window, not a build pin: `~> 1.20`
      # admits >= 1.20.0 and < 2.0.0. The compatibility evidence below names
      # the exact runtime exercised; this requirement is not a build pin.
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      lockfile: lockfile(),
      description: description(),
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:ecto_sql, :ex_unit, :mix, :oban, :plug, :igniter]],
      test_paths: ["test"],
      test_ignore_filters: [&String.starts_with?(&1, "test/compile_fixtures/")],
      aliases: aliases()
    ]
  end

  def cli, do: [preferred_envs: [precommit: :test]]

  defp aliases do
    [
      precommit: [
        "hex.audit",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "spark.cheat_sheets --check --extensions AshOnetime.Resource",
        "deps.audit"
      ]
    ]
  end

  def application do
    [mod: {AshOnetime.Application, []}, extra_applications: [:crypto, :logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ash, ash_requirement()},
      # Security floors (ADR 0004): AshPostgres 2.15.2 fixes tenant-isolation issues;
      # AshSql 0.8.6 fixes query-cache security. AshPostgres owns AshSql startup,
      # so ash_sql stays runtime: false.
      {:ash_postgres, "~> 2.15 and >= 2.15.2"},
      {:ash_sql, "~> 0.8 and >= 0.8.6", runtime: false},
      {:spark, "~> 2.7"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.4"},
      # Optional integrations are host-owned: the host declares and starts them.
      # runtime: false keeps them out of ash_onetime's runtime application list.
      # Their presence must not add a runtime dependency for other consumers.
      # Ash requires stream_data in every environment, so it stays resolvable there.
      # It is used for property tests and excluded from runtime applications.
      {:plug, "~> 1.20", optional: true, runtime: false},
      {:oban, "~> 2.23", optional: true, runtime: false},
      {:igniter, "~> 0.8 and >= 0.8.4", optional: true, runtime: false},
      # Optional Mint constrains the Igniter HTTP closure without adding HTTP to core.
      # Mint 1.10.2 fixes HTTP/2 memory exhaustion and HTTP/1 response smuggling.
      # Consumers retain the patched 1.10 line; the development lock uses current 1.x.
      {:mint, "~> 1.10 and >= 1.10.2", optional: true, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:simple_sat, "~> 0.1 and >= 0.1.1", only: :test, runtime: false},
      {:stream_data, "~> 1.4", runtime: false}
    ]
  end

  # Consumer Ash support is >= 3.37.2 and < 4.0.0 (security floors: ADR 0004).
  # ASH_ONETIME_ASH_VERSION may pin only a plain release inside that range;
  # latest or unset preserves the floating consumer requirement.
  @ash_floor "3.37.2"

  defp ash_requirement do
    case System.get_env("ASH_ONETIME_ASH_VERSION") do
      version when version in [nil, "", "latest"] -> ">= #{@ash_floor} and < 4.0.0"
      version -> pinned_ash_requirement(version)
    end
  end

  # Each Ash cell CI runs has its own committed lock, so every fetch is --check-locked:
  # mix.lock for the floating requirement and locks/ash-floor/mix.lock for the declared floor.
  # Each is resolved with mix deps.get where mix.exs changes and committed with it; the Work
  # workflow's lock job only checks and audits them. Neither is written by hand.
  defp lockfile do
    if System.get_env("ASH_ONETIME_ASH_VERSION") == @ash_floor,
      do: "locks/ash-floor/mix.lock",
      else: "mix.lock"
  end

  defp pinned_ash_requirement(version) do
    with {:ok, parsed} <- Version.parse(version),
         true <- parsed.pre == [],
         true <- is_nil(parsed.build),
         true <- Version.compare(parsed, @ash_floor) != :lt,
         true <- Version.compare(parsed, "4.0.0") == :lt do
      "== #{version}"
    else
      _ ->
        Mix.raise("""
        ASH_ONETIME_ASH_VERSION must be a plain release version inside the published \
        Ash range >= #{@ash_floor} and < 4.0.0 (no pre-release or build-metadata \
        suffix — SemVer orders them inside the range while Hex would never resolve \
        them for the floating requirement), or "latest"/unset for the floating \
        requirement; got: #{inspect(version)}. Unset the variable or pin an in-range \
        release version — publishing with an out-of-range pin exported would freeze \
        a wrong exact requirement into the package.\
        """)
    end
  end

  defp description do
    "An Ash extension for explicit idempotency and one-time nonce semantics"
  end

  defp package do
    [
      files: [
        "lib",
        "priv/templates",
        "priv/vectors",
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
      maintainers: ["Russ Palermo"],
      keywords: ["ash", "idempotency", "nonce", "anti-replay", "replay-protection"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "documentation/getting-started.md",
        "documentation/dsl.md",
        "documentation/idempotency.md",
        "documentation/one-time-nonces.md",
        "documentation/tokens.md",
        "documentation/external-effects.md",
        "documentation/context-boundary.md",
        "documentation/replay.md",
        "documentation/custom-lifecycle.md",
        "documentation/transaction-owned-admission.md",
        "documentation/errors.md",
        "documentation/operations.md",
        "documentation/security.md",
        "documentation/recipes.md",
        "documentation/phoenix.md",
        "documentation/telemetry.md",
        "documentation/upgrading.md",
        "documentation/faq.md",
        "documentation/livebooks/idempotency.livemd",
        "documentation/livebooks/nonces.livemd",
        "documentation/livebooks/external-recovery.livemd",
        "documentation/livebooks/context-boundary.livemd",
        "documentation/dsls/DSL-AshOnetime.Resource.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "usage-rules.md",
        "CHANGELOG.md"
      ]
    ]
  end
end
