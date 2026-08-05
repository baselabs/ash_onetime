defmodule AshOnetime.ArchitectureTest do
  use ExUnit.Case, async: true

  @production_modules [
    AshOnetime,
    AshOnetime.Admission,
    AshOnetime.Admission.State,
    AshOnetime.Cache,
    AshOnetime.Cache.Config,
    AshOnetime.Cache.Entry,
    AshOnetime.Cache.None,
    AshOnetime.Canonical,
    AshOnetime.Canonical.Decoder,
    AshOnetime.Change,
    AshOnetime.Clock,
    AshOnetime.Codec,
    AshOnetime.Codec.ActionResult,
    AshOnetime.Codec.JSON,
    AshOnetime.Codec.Resource,
    AshOnetime.Error,
    AshOnetime.ExternalEffect,
    AshOnetime.ExternalRecovery,
    AshOnetime.Fingerprint,
    AshOnetime.GenericAction,
    AshOnetime.KeyResolver,
    AshOnetime.KeySource,
    AshOnetime.Oban.CleanupWorker,
    AshOnetime.Plug,
    AshOnetime.ReplaySafety,
    AshOnetime.Resource,
    AshOnetime.Resource.Info,
    AshOnetime.Resource.Onetime.Protect,
    AshOnetime.Resource.Onetime.Protect.Options,
    AshOnetime.Resource.Onetime.Protect.Response,
    AshOnetime.Resource.Onetime.Protect.Response.Options,
    AshOnetime.Resource.Protection,
    AshOnetime.Resource.Response,
    AshOnetime.Resource.Transformer,
    AshOnetime.Resource.Verifier,
    AshOnetime.Response,
    AshOnetime.Response.Contract,
    AshOnetime.ResponseClassifier,
    AshOnetime.Scope,
    AshOnetime.Signer,
    AshOnetime.Signer.Ed25519,
    AshOnetime.Signer.HMAC,
    AshOnetime.Store,
    AshOnetime.Store.Claim,
    AshOnetime.Store.Claim.Request,
    AshOnetime.Store.Postgres,
    AshOnetime.Store.Postgres.Target,
    AshOnetime.Store.Result,
    AshOnetime.Telemetry,
    AshOnetime.Token,
    AshOnetime.Verified,
    AshOnetime.Verifier,
    AshOnetime.Window,
    Mix.Tasks.AshOnetime.Gen.Migrations,
    Mix.Tasks.AshOnetime.Install,
    Mix.Tasks.AshOnetime.Prune
  ]

  @documented_modules [
    AshOnetime,
    AshOnetime.Cache,
    AshOnetime.Cache.Entry,
    AshOnetime.Cache.None,
    AshOnetime.Canonical,
    AshOnetime.Clock,
    AshOnetime.Codec,
    AshOnetime.Codec.ActionResult,
    AshOnetime.Codec.JSON,
    AshOnetime.Codec.Resource,
    AshOnetime.Error,
    AshOnetime.ExternalEffect,
    AshOnetime.Fingerprint,
    AshOnetime.KeyResolver,
    AshOnetime.KeySource,
    AshOnetime.Oban.CleanupWorker,
    AshOnetime.Plug,
    AshOnetime.ReplaySafety,
    AshOnetime.Resource,
    AshOnetime.Resource.Info,
    AshOnetime.ResponseClassifier,
    AshOnetime.Scope,
    AshOnetime.Signer,
    AshOnetime.Signer.Ed25519,
    AshOnetime.Signer.HMAC,
    AshOnetime.Telemetry,
    AshOnetime.Token,
    AshOnetime.Verified,
    AshOnetime.Verifier,
    AshOnetime.Window,
    Mix.Tasks.AshOnetime.Gen.Migrations,
    Mix.Tasks.AshOnetime.Install,
    Mix.Tasks.AshOnetime.Prune
  ]

  @exports %{
    AshOnetime => [],
    AshOnetime.Cache => [authoritative_payload: 2, config: 1, store: 3],
    AshOnetime.Cache.Entry => [__struct__: 0, __struct__: 1],
    AshOnetime.Cache.None => [delete: 1, get: 1, put: 3],
    AshOnetime.Canonical => [encode: 1],
    AshOnetime.Clock => [now: 0],
    AshOnetime.Codec => [
      ash_resource?: 1,
      hard_limits: 0,
      max_bytes: 1,
      structural_limits: 1,
      validate_tag: 1,
      validate_value: 2,
      validate_value: 3
    ],
    AshOnetime.Codec.ActionResult => [
      decode: 4,
      decode_envelope: 5,
      encode: 3,
      encode_envelope: 4,
      format_tag: 0
    ],
    AshOnetime.Codec.JSON => [
      decode: 4,
      encode: 3,
      format_tag: 0,
      pack: 4,
      unpack: 4,
      unpack_shape: 4
    ],
    AshOnetime.Codec.Resource => [
      decode: 4,
      decode_envelope: 5,
      encode: 3,
      encode_envelope: 4,
      format_tag: 0,
      normalize: 2,
      require_normalized: 2
    ],
    AshOnetime.Error => [__struct__: 0, __struct__: 1, exception: 1, message: 1, new: 2, new: 3],
    AshOnetime.ExternalEffect => [operation_key: 1, put_result: 3, result: 1],
    AshOnetime.Fingerprint => [compute: 1, compute: 2],
    AshOnetime.KeyResolver => [],
    AshOnetime.KeySource => [normalize: 1, references: 1],
    AshOnetime.Oban.CleanupWorker => [
      __opts__: 0,
      backoff: 1,
      new: 1,
      new: 2,
      perform: 1,
      timeout: 1
    ],
    AshOnetime.Plug => [call: 2, init: 1],
    AshOnetime.ReplaySafety => [],
    AshOnetime.Resource => [
      __set_and_validate_options__: 4,
      add_extensions: 0,
      dsl_patches: 0,
      module_imports: 0,
      module_prefix: 0,
      persisters: 0,
      sections: 0,
      transformers: 0,
      verifiers: 0
    ],
    AshOnetime.Resource.Info => [protected?: 2, protection: 2, protections: 1, strategy: 2],
    AshOnetime.ResponseClassifier => [classify: 3],
    AshOnetime.Scope => [normalize: 1, references: 1],
    AshOnetime.Signer => [],
    AshOnetime.Signer.Ed25519 => [algorithm: 0, sign: 2, verify: 3],
    AshOnetime.Signer.HMAC => [algorithm: 0, sign: 2, verify: 3],
    AshOnetime.Telemetry => [
      admission: 5,
      cache: 4,
      cleanup: 5,
      conflict: 4,
      encoding: 5,
      external_recovery: 5,
      fingerprint_mismatch: 3,
      replay: 5,
      store_uncertainty: 4,
      untracked_execution: 3,
      verification: 5
    ],
    AshOnetime.Token => [__struct__: 0, __struct__: 1, mint: 2, sign: 3, verify: 3],
    AshOnetime.Verified => [__struct__: 0, __struct__: 1],
    AshOnetime.Verifier => [],
    AshOnetime.Window => [cleanup_after: 3, cleanup_skew_margin_seconds: 0, validate: 5],
    Mix.Tasks.AshOnetime.Gen.Migrations => [render: 2, run: 1, timestamp: 0],
    Mix.Tasks.AshOnetime.Install => [
      igniter: 1,
      info: 2,
      installer?: 0,
      parse_argv: 1,
      run: 1,
      supports_umbrella?: 0
    ],
    Mix.Tasks.AshOnetime.Prune => [run: 1]
  }

  test "the production module and public documentation censuses are exact" do
    {:ok, application_modules} = :application.get_key(:ash_onetime, :modules)

    actual =
      Enum.reject(application_modules, fn module ->
        name = Atom.to_string(module)

        String.starts_with?(name, "Elixir.AshOnetime.Test") or
          String.starts_with?(name, "Elixir.Inspect.AshOnetime.Test")
      end)

    assert Enum.sort(actual) == Enum.sort(@production_modules)

    documented =
      Enum.filter(actual, fn module ->
        match?({:docs_v1, _, _, _, %{}, _, _}, Code.fetch_docs(module))
      end)

    assert Enum.sort(documented) == Enum.sort(@documented_modules)
  end

  test "dependency, package, and application boundaries are exact" do
    dependency_names = Mix.Project.config()[:deps] |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    assert dependency_names ==
             Enum.sort([
               :ash,
               :ash_postgres,
               :credo,
               :dialyxir,
               :ecto_sql,
               :ex_doc,
               :igniter,
               :jason,
               :mix_audit,
               :oban,
               :plug,
               :postgrex,
               :spark,
               :stream_data,
               :telemetry
             ])

    assert Mix.Project.config()[:package][:files] == [
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
           ]

    assert AshOnetime.MixProject.application() == [extra_applications: [:crypto, :logger]]
    assert Application.spec(:ash_onetime, :mod) in [nil, []]
  end

  test "documented public exports are exact" do
    actual = Map.new(@documented_modules, &{&1, &1.__info__(:functions)})
    assert actual == @exports
  end

  test "reference-project and provider-crypto dependencies stay absent" do
    source = Path.wildcard("lib/**/*.ex") |> Enum.map_join("\n", &File.read!/1)

    for forbidden <- [
          "ash_webhook_it",
          "core_os",
          "qorpay",
          "bounded_authority",
          "Aws.KMS",
          "GoogleApi.CloudKMS",
          "ExAws"
        ] do
      refute String.contains?(String.downcase(source), String.downcase(forbidden))
    end
  end
end
