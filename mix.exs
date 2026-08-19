defmodule AshOnetime.MixProject do
  use Mix.Project

  @version "0.7.0"
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
      dialyzer: [plt_add_apps: [:ecto_sql, :ex_unit, :mix]],
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

  # `>= 3.31.3 and < 4.0.0` is the published requirement every consumer resolves against. The
  # floor is 3.31.3: EEF-CVE-2026-55736 (private action arguments settable by user input, fixed
  # in 3.29.3), EEF-CVE-2026-70395 (predicate injection in manage_relationship belongs_to
  # lookup disclosing secret lookup keys, fixed in 3.31.1), EEF-CVE-2026-69659 (memory
  # exhaustion via unbounded keyset-cursor deserialization, fixed in 3.31.1), and
  # EEF-CVE-2026-67579 (filter expression injection via a forged keyset pagination cursor —
  # HIGH, fixed only in 3.31.3) all affect Ash below 3.31.3 — a security library must not
  # admit a vulnerable floor. The CI compatibility matrix sets ASH_ONETIME_ASH_VERSION to pin
  # one exact Ash per cell (the floor and each later minor); `latest`/unset keeps the floating
  # requirement so the newest published Ash is exercised. The namespaced var name is extremely
  # unlikely to collide with anything in a consumer's environment, so a published build sees
  # the full requirement. A pin is validated at project-config evaluation time: it must be a
  # version inside the published range, else Mix.raise fires — a publish with an out-of-range
  # pin exported would otherwise silently freeze a wrong exact requirement into the package.
  @ash_floor "3.31.3"

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
