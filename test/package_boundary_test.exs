defmodule AshOnetime.PackageBoundaryTest do
  use AshOnetime.Test.DataCase, async: false

  alias AshOnetime.Test.Migration
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  # The one application callback the package owns: the supervision tree for bounded
  # callbacks (KeyCustody and verifier workers) and the maintenance installs.
  @package_application "lib/ash_onetime/application.ex"

  Code.require_file("../scripts/reference_projects.exs", __DIR__)

  alias AshOnetime.ReferenceProjects

  test "the live package contains no forbidden boundary violations" do
    assert violations(source_entries(), Mix.Project.config()[:deps]) == []
  end

  test "listed reference-project dependencies and names are rejected" do
    control = ReferenceProjects.control()
    listed = String.to_atom(control)

    deps = [
      {listed, "~> 0.1"},
      {listed, git: "https://example.invalid/project.git"},
      {:unlisted, path: "../BaseLabs/unlisted"},
      {:unlisted, "~> 1.0"}
    ]

    assert Enum.count(violations([], deps), &match?({:forbidden_dependency, _, _}, &1)) == 3

    assert [{:reference_project, "lib/example.ex"}] =
             violations([{"lib/example.ex", "# depends on #{String.upcase(control)}"}], [])

    assert violations([{"lib/example.ex", "# #{control}_suffix is another token"}], []) == []
  end

  test "runtime application callbacks outside the package application are rejected" do
    callback = "use Application\ndef start(_type, _args), do: :ok"

    assert [{:application_callback, "lib/example.ex"}] =
             violations([{"lib/example.ex", callback}], [])

    assert [{:application_callback, "lib/ash_onetime/application_extra.ex"}] =
             violations([{"lib/ash_onetime/application_extra.ex", callback}], [])
  end

  test "secret literals are rejected" do
    entries = [{"lib/example.ex", ~s|config :example, secret: "literal-secret"|}]

    assert [{:secret_literal, "lib/example.ex"}] = violations(entries, [])
  end

  test "provider-specific signature modules are rejected" do
    entries = [{"lib/stripe_signature.ex", "defmodule AshOnetime.StripeSignature do\nend"}]

    assert [{:provider_signature_module, "lib/stripe_signature.ex"}] = violations(entries, [])
  end

  test "the database harness is pinned to its dedicated PostgreSQL 18 database" do
    # test_helper already failed closed unless DATABASE_URL targets the
    # dedicated shape (postgres user, loopback host, ash_onetime_test name,
    # non-default port); this pins the Repo to that SAME guarded URL — no
    # independent fallback target — plus the live isolation check against the
    # connected server.
    database_url = System.fetch_env!("DATABASE_URL")

    assert Application.fetch_env!(:ash_onetime, Repo)[:url] == database_url

    assert :ok = Migration.assert_isolated_database!()
  end

  test "the live harness uses the checked platform engine and its disposable auth contract" do
    engine = File.read!(Path.expand("../.github/postgres.ref", __DIR__))
    [_, version] = Regex.run(~r/:([0-9]+\.[0-9]+)-inputs-/, engine)

    assert [[^version, "/var/lib/pg/data", "/tmp", "scram-sha-256"]] =
             SQL.query!(
               Repo,
               "SELECT split_part(current_setting('server_version'),' ',1), current_setting('data_directory'), current_setting('unix_socket_directories'), current_setting('password_encryption')",
               []
             ).rows

    rules = SQL.query!(Repo, "SELECT type, auth_method, error FROM pg_hba_file_rules", []).rows
    assert Enum.any?(rules, &match?(["local", "trust", nil], &1))
    assert Enum.any?(rules, &match?(["host", "scram-sha-256", nil], &1))

    assert Enum.all?(rules, fn
             ["local", "trust", nil] -> true
             [type, "scram-sha-256", nil] when type in ["host", "hostssl", "hostnossl"] -> true
             _ -> false
           end)
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

      if ReferenceProjects.listed?(name) or
           Regex.match?(~r/(?:Base|BaseLabs)\//, serialized_options) do
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
      path != @package_application and
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
    |> maybe_add(ReferenceProjects.mentioned?(source), {:reference_project, path})
    |> Enum.reverse()
  end

  defp maybe_add(violations, true, violation), do: [violation | violations]
  defp maybe_add(violations, false, _violation), do: violations

  defp source_entries do
    ["lib/**/*.ex", "config/**/*.exs"]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.map(&{&1, File.read!(&1)})
  end
end
