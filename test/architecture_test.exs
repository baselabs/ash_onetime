defmodule AshOnetime.ArchitectureTest do
  use ExUnit.Case, async: true

  @production_modules [
    AshOnetime,
    AshOnetime.Admission,
    AshOnetime.Admission.State,
    AshOnetime.Cache,
    AshOnetime.Cache.Config,
    AshOnetime.Cache.Entry,
    AshOnetime.Cache.Ets,
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
    AshOnetime.Oban.PartitionWorker,
    AshOnetime.Oban.ReapWorker,
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
    Mix.Tasks.AshOnetime.Gen.RollForward,
    Mix.Tasks.AshOnetime.Install,
    Mix.Tasks.AshOnetime.Prune,
    Mix.Tasks.AshOnetime.Reap,
    Mix.Tasks.AshOnetime.RollPartitions
  ]

  @documented_modules [
    AshOnetime,
    AshOnetime.Cache,
    AshOnetime.Cache.Entry,
    AshOnetime.Cache.Ets,
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
    AshOnetime.Oban.PartitionWorker,
    AshOnetime.Oban.ReapWorker,
    AshOnetime.Plug,
    AshOnetime.ReplaySafety,
    AshOnetime.Resource,
    AshOnetime.Resource.Info,
    AshOnetime.Resource.Protection,
    AshOnetime.Resource.Response,
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
    Mix.Tasks.AshOnetime.Gen.RollForward,
    Mix.Tasks.AshOnetime.Install,
    Mix.Tasks.AshOnetime.Prune,
    Mix.Tasks.AshOnetime.Reap,
    Mix.Tasks.AshOnetime.RollPartitions
  ]

  @exports %{
    AshOnetime => [replayed?: 1, reserved_verification_inputs: 0],
    AshOnetime.Cache => [authoritative_payload: 2, config: 1, key: 1, store: 3],
    AshOnetime.Cache.Entry => [],
    AshOnetime.Cache.Ets => [
      child_spec: 1,
      clear: 0,
      delete: 1,
      get: 1,
      handle_call: 3,
      handle_cast: 2,
      init: 1,
      max_entries: 0,
      put: 3,
      start_link: 0,
      start_link: 1,
      terminate: 2
    ],
    AshOnetime.Cache.None => [delete: 1, get: 1, put: 3],
    AshOnetime.Canonical => [encode: 1],
    AshOnetime.Clock => [now: 0],
    AshOnetime.Codec => [
      ash_resource?: 1,
      hard_limits: 0,
      max_bytes: 1,
      protect_only_ceilings: 0,
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
    AshOnetime.Error => [
      code: 1,
      exception: 1,
      message: 1,
      new: 2,
      new: 3
    ],
    AshOnetime.ExternalEffect => [operation_key: 1, put_result: 3, result: 1],
    AshOnetime.Fingerprint => [compute: 1, compute: 2],
    AshOnetime.KeyResolver => [],
    AshOnetime.KeySource => [normalize: 1, references: 1],
    AshOnetime.Oban.CleanupWorker => [backoff: 1, perform: 1],
    AshOnetime.Oban.PartitionWorker => [backoff: 1, perform: 1],
    AshOnetime.Oban.ReapWorker => [backoff: 1, perform: 1],
    AshOnetime.Plug => [call: 2, init: 1],
    AshOnetime.ReplaySafety => [],
    AshOnetime.Resource => [],
    AshOnetime.Resource.Info => [protected?: 2, protection: 2, protections: 1, strategy: 2],
    AshOnetime.Resource.Protection => [],
    AshOnetime.Resource.Response => [],
    AshOnetime.ResponseClassifier => [classify: 3],
    AshOnetime.Scope => [normalize: 1, references: 1],
    AshOnetime.Signer => [],
    AshOnetime.Signer.Ed25519 => [algorithm: 0, sign: 2, verify: 3],
    AshOnetime.Signer.HMAC => [algorithm: 0, sign: 2, verify: 3],
    AshOnetime.Telemetry => [
      admission: 5,
      attach: 0,
      attach: 1,
      cache: 4,
      cleanup: 5,
      conflict: 4,
      detach: 0,
      detach: 1,
      encoding: 5,
      external_recovery: 5,
      fingerprint_mismatch: 3,
      handle_event: 4,
      handler_id: 0,
      handler_id: 1,
      reap: 5,
      replay: 5,
      store_uncertainty: 4,
      uncertain_exception: 2,
      untracked_execution: 3,
      verification: 5
    ],
    AshOnetime.Token => [mint: 2, sign: 3, verify: 3],
    AshOnetime.Verified => [],
    AshOnetime.Verifier => [],
    AshOnetime.Window => [cleanup_after: 3, cleanup_skew_margin_seconds: 0, validate: 5],
    Mix.Tasks.AshOnetime.Gen.Migrations => [
      render: 2,
      render_roll_forward: 2,
      run: 1,
      timestamp: 0
    ],
    Mix.Tasks.AshOnetime.Gen.RollForward => [run: 1],
    Mix.Tasks.AshOnetime.Install => [
      igniter: 1,
      info: 2,
      run: 1
    ],
    Mix.Tasks.AshOnetime.Prune => [run: 1],
    Mix.Tasks.AshOnetime.Reap => [run: 1],
    Mix.Tasks.AshOnetime.RollPartitions => [run: 1]
  }

  # The exact-export census compares a hand-maintained `@exports` snapshot against
  # `module.__info__(:functions)`. For modules built on an injecting framework
  # (e.g. `use Splode.Error`), `__info__(:functions)` also lists functions the
  # framework's macros expand into the host module at compile time — and that injected
  # set grows across dependency versions, breaking the census on drift the project
  # does not own. `AshOnetime.Error` is the only `use Splode.Error` module in the
  # documented set; CI's compat matrix runs `mix deps.unlock ash && mix deps.update
  # ash` (.github/workflows/ci.yml), which resolves the newest Splode satisfying
  # `~> 0.3`, and Splode 0.3.2 added `keyword_list_options?/0` to the injected set —
  # so CI red-barred while the 0.3.1-committed lock stayed green locally.
  #
  # Rather than hand-maintain an exempt allowlist (which would rot the same way and
  # could not mechanically detect a project override of an injected fn, or a framework
  # removing one), the census derives the project-authored exports from each module's
  # OWN source AST (`project_defined_arity_set/1`) and compares the snapshot only
  # against those. `__info__(:functions)` minus the source-derived set is the live
  # framework-injected surface — which closes both drift directions: a project
  # override reclassifies the fn as authored (so it falls under the guard), and a
  # framework removal drops it from `__info__` (so a stale snapshot entry fails loud).

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
    # Compare the `@exports` snapshot only against the exports each module AUTHORS
    # (parsed from its own source AST), not the framework-injected ones. This keeps
    # the census robust to framework-version drift in the injected set (e.g. Splode
    # adding `keyword_list_options?/0` across a patch bump) while still guarding every
    # project-owned export — and a project override of an injected fn, or a framework
    # removing one, both surface as a snapshot mismatch.
    actual =
      Map.new(@documented_modules, fn module ->
        {module, project_owned_arity_set(module)}
      end)

    assert actual == @exports
  end

  test "AshOnetime.Error is a Splode error so its typed code survives the Ash pipeline" do
    # ARCH-1: AshOnetime.Error must be a Splode leaf of class :invalid so Ash preserves it
    # (instead of wrapping it as an unknown error and losing the typed :code). A bare
    # defexception would make splode_error?/0 undefined and ash_error?/1 false.
    #
    # Force-load the module before the membership check: `function_exported?/3` reports
    # the CURRENT beam state, so a module no other test has touched yet reads as
    # unexported, which made this assertion seed-dependent (failed in isolation,
    # passed once a neighboring test loaded the module).
    Code.ensure_compiled(AshOnetime.Error)

    assert function_exported?(AshOnetime.Error, :splode_error?, 0)
    assert AshOnetime.Error.splode_error?() == true
    assert AshOnetime.Error.error_class?() == false

    error = AshOnetime.Error.new(:nonce_already_used, "nonce was already used")
    assert Ash.Error.ash_error?(error) == true
    assert error.class == :invalid
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

  # The set of `{name, arity}` the module AUTHORS in its own source, parsed from the
  # beam's recorded source path. Guards and default args (`\\`) are unwrapped so a
  # multi-arity clause yields every effective arity. Used to separate project-owned
  # exports from framework-injected ones without a hand-maintained allowlist.
  defp project_defined_arity_set(module) do
    source_path = List.to_string(module.__info__(:compile)[:source])
    {:ok, source} = File.read(source_path)
    {:ok, ast} = Code.string_to_quoted(source, columns: true)

    {_, defined} =
      Macro.prewalk(ast, [], fn
        {:def, _, [head | _rest]} = node, acc ->
          {node, arity_pairs(head) ++ acc}

        node, acc ->
          {node, acc}
      end)

    MapSet.new(defined)
  end

  # Unwraps a `def` head (which may be guarded by `when`) into its `{name, arity}`
  # pairs, expanding default args: `def f(a, b \\ nil)` yields `{f, 2}` and `{f, 1}`.
  defp arity_pairs({:when, _, [head | _guards]}), do: arity_pairs(head)

  defp arity_pairs({name, _meta, args}) when is_atom(name) and is_list(args) do
    base = length(args)
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    Enum.map(0..defaults, fn delta -> {name, base - delta} end)
  end

  defp arity_pairs({name, _meta, nil}) when is_atom(name), do: [{name, 0}]
  defp arity_pairs(_), do: []

  # The exports the module owns: those present in `__info__(:functions)` AND authored
  # in its source — i.e. excluding anything a framework macro injected.
  defp project_owned_arity_set(module) do
    module.__info__(:functions)
    |> MapSet.new()
    |> MapSet.intersection(project_defined_arity_set(module))
    |> MapSet.to_list()
    |> Enum.sort()
  end
end
