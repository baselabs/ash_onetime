defmodule AshOnetime.MixProject do
  use Mix.Project

  @version "1.3.0"
  @source_url "https://github.com/baselabs/ash_onetime"

  def project do
    [
      app: :ash_onetime,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      # :oban/:plug/:igniter/:mint/:stream_data/:ash_sql are all runtime: false, so
      # dialyxir no longer seeds the PLT with them on its own, while the guarded
      # integration modules still analyze against their beams — they must be added
      # explicitly. :ash_sql stays seeded transitively through ash_postgres's own
      # app spec; :mint needs no explicit entry because nothing in lib/ compiles
      # against it (it binds only inside the optional installer closure).
      dialyzer: [plt_add_apps: [:ecto_sql, :ex_unit, :mix, :oban, :plug, :igniter]],
      test_paths: ["test"],
      test_ignore_filters: [&String.starts_with?(&1, "test/compile_fixtures/")]
    ]
  end

  def application do
    [extra_applications: [:crypto, :logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ash, ash_requirement()},
      # Security floor (ADR 0004): AshPostgres 2.13.0 is where EEF-CVE-2026-78699 is
      # fixed, and AshPostgres still admits older ash_sql releases — the explicit
      # ash_sql floor below closes that gap for consumers. `runtime: false` keeps
      # AshPostgres the owner of ash_sql's startup; the < 1.0.0 cap is the same
      # matrix-extension posture as the Ash < 4.0.0 bound (a breaking major is
      # proven in CI before the cap moves).
      {:ash_postgres, "~> 2.13"},
      {:ash_sql, "~> 0.7 and >= 0.7.1", runtime: false},
      {:spark, "~> 2.7"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.4"},
      # The three optional integrations (Plug module, Oban workers, Igniter installer) are
      # host-owned surfaces: the host lists the dep itself, so the host's own app spec starts
      # it. `runtime: false` keeps an attached optional out of ash_onetime's generated
      # `applications` list — otherwise every host that carries the dep inherits it as a
      # runtime application of ash_onetime (the app-spec leak flagged by consumer-side audit).
      # stream_data is property-test-only here; it cannot take `only: :test` because ash
      # itself requires stream_data unrestricted, and Mix rejects a direct entry whose
      # :only excludes an env a sibling needs it in — so it is kept resolvable in every env
      # but kept out of the runtime applications list.
      {:plug, "~> 1.20", optional: true, runtime: false},
      {:oban, "~> 2.23", optional: true, runtime: false},
      {:igniter, "~> 0.8 and >= 0.8.4", optional: true, runtime: false},
      # Constrain the installer's HTTP closure without adding HTTP to core consumers:
      # mint reaches a tree only through igniter → req → finch, so an optional
      # requirement binds exactly the closure that carries it. Same next-major cap
      # posture as ash_sql above.
      {:mint, "~> 1.10", optional: true, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.4", runtime: false}
    ]
  end

  # `>= 3.33.4 and < 4.0.0` is the consumer requirement. ADR 0004 records the
  # advisory inventory through 2026-09-16: EEF-CVE-2026-86338 (field policies fail to
  # filter-nil forbidden calculations and aggregates — an information-disclosure
  # oracle) is fixed only in 3.33.4; EEF-CVE-2026-82752 and the rest of the
  # EEF-CVE-2026-82xxx batch are fixed at or below this floor.
  # The CI compatibility matrix sets ASH_ONETIME_ASH_VERSION to pin
  # one exact Ash per cell (the floor and each later minor); `latest`/unset keeps the floating
  # requirement so the newest published Ash is exercised. The namespaced var name is extremely
  # unlikely to collide with anything in a consumer's environment, so a published build sees
  # the full requirement. A pin is validated at project-config evaluation time: it must be a
  # version inside the published range, else Mix.raise fires — a publish with an out-of-range
  # pin exported would otherwise silently freeze a wrong exact requirement into the package.
  @ash_floor "3.33.4"

  defp ash_requirement do
    case System.get_env("ASH_ONETIME_ASH_VERSION") do
      version when version in [nil, "", "latest"] -> ">= #{@ash_floor} and < 4.0.0"
      version -> pinned_ash_requirement(version)
    end
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
        "documentation/external-effects.md",
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
        "documentation/dsls/DSL-AshOnetime.Resource.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "usage-rules.md",
        "CHANGELOG.md"
      ]
    ]
  end
end
