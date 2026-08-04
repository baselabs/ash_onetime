defmodule AshOnetime.PackageBoundaryTest do
  use AshOnetime.Test.DataCase, async: false

  alias AshOnetime.Test.Migration
  alias AshOnetime.Test.Repo

  @forbidden_dependencies [
    :ash_age,
    :ash_webhook_it,
    :bounded_authority,
    :bounded_authority_protocol,
    :core_os,
    :qorpay
  ]

  test "the live package contains no forbidden boundary violations" do
    assert violations(source_entries(), Mix.Project.config()[:deps]) == []
  end

  test "forbidden reference-project dependencies are rejected" do
    deps = [
      {:ash_age, path: "../ash_age"},
      {:ash_webhook_it, git: "https://example.invalid/ash_webhook_it.git"},
      {:bounded_authority_protocol, "~> 0.1"},
      {:core_os, path: "../../GPT/core_os"},
      {:qorpay, path: "../../Qor/qorpay"}
    ]

    assert Enum.count(violations([], deps), &match?({:forbidden_dependency, _, _}, &1)) == 5
  end

  test "runtime application callbacks are rejected" do
    entries = [{"lib/example.ex", "use Application\ndef start(_type, _args), do: :ok"}]

    assert [{:application_callback, "lib/example.ex"}] = violations(entries, [])
  end

  test "secret literals are rejected" do
    entries = [{"lib/example.ex", ~s|config :example, secret: "literal-secret"|}]

    assert [{:secret_literal, "lib/example.ex"}] = violations(entries, [])
  end

  test "provider-specific signature modules are rejected" do
    entries = [{"lib/stripe_signature.ex", "defmodule AshOnetime.StripeSignature do\nend"}]

    assert [{:provider_signature_module, "lib/stripe_signature.ex"}] = violations(entries, [])
  end

  test "version-suffixed durable identifiers are rejected" do
    entries = [
      {"lib/token_v2.ex", "defmodule AshOnetime.TokenV2 do\n  def decode_v2, do: :ok\nend"}
    ]

    assert [{:version_suffix, "lib/token_v2.ex"}] = violations(entries, [])
  end

  test "the database harness is pinned to its dedicated PostgreSQL 18 database" do
    repo_config = Application.fetch_env!(:ash_onetime, Repo)

    assert repo_config[:url] ==
             "ecto://postgres:postgres@127.0.0.1:18841/ash_onetime_test"

    assert :ok = Migration.assert_isolated_database!()
  end

  defp violations(entries, deps) do
    dependency_violations(deps) ++
      Enum.flat_map(entries, fn {path, source} ->
        source_violations(path, source)
      end)
  end

  defp dependency_violations(deps) do
    Enum.flat_map(deps, fn dependency ->
      {name, options} = dependency_name_and_options(dependency)
      serialized_options = inspect(options)

      if name in @forbidden_dependencies or
           Regex.match?(~r/(?:Base|BaseLabs|Qor|GPT)\//, serialized_options) do
        [{:forbidden_dependency, name, options}]
      else
        []
      end
    end)
  end

  defp dependency_name_and_options({name, options}) when is_list(options), do: {name, options}

  defp dependency_name_and_options({name, _requirement, options}) when is_list(options),
    do: {name, options}

  defp dependency_name_and_options({name, _requirement}), do: {name, []}

  defp source_violations(path, source) do
    []
    |> maybe_add(
      Regex.match?(
        ~r/\b(?:use Application|@behaviour Application|def start\s*\(_type,\s*_args\))/,
        source
      ),
      {:application_callback, path}
    )
    |> maybe_add(
      Regex.match?(
        ~r/\b(?:api_key|password|private_key|secret)\s*[:=]\s*["'][^"']+["']/i,
        source
      ),
      {:secret_literal, path}
    )
    |> maybe_add(
      Regex.match?(
        ~r/defmodule\s+\S*(?:Stripe|GitHub|Slack|Twilio|Provider)\S*(?:Signature|Verifier)/i,
        source
      ),
      {:provider_signature_module, path}
    )
    |> maybe_add(version_suffix?(path, source), {:version_suffix, path})
    |> Enum.reverse()
  end

  defp version_suffix?(path, source) do
    Regex.match?(~r/(?:^|[\/_])[^\/]*_v\d+(?:\.|_|\/|$)/i, path) or
      Regex.match?(~r/\b(?:defmodule|def|defp)\s+\S*(?:_v\d+|V\d+)\b/, source)
  end

  defp maybe_add(violations, true, violation), do: [violation | violations]
  defp maybe_add(violations, false, _violation), do: violations

  defp source_entries do
    ["lib/**/*.ex", "config/**/*.exs"]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.map(&{&1, File.read!(&1)})
  end
end
