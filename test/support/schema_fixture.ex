defmodule AshOnetime.Test.SchemaFixture do
  @moduledoc false
  alias AshOnetime.Test.Repo
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator

  def install!(c, "inventory_facts") do
    migrate!(c, Generator.render_fact_tables(Repo, fact_tables: ["inventory_facts"]))
  end

  def install!(c, "ash_onetime_maintenance_runs") do
    ddl =
      File.read!("priv/templates/migrations/maintenance/runs.sql")
      |> String.replace("@schema@", "\"#{c.schema}\"")

    migrate_ddl!(c, ddl)
  end

  def install!(c, table) do
    source =
      Generator.render(Repo,
        maintenance_role: c.maintainer,
        hash_partitions: c[:hash_partitions]
      )

    ddl =
      Regex.scan(~r/execute\("""\n(.*?)\n    """\)/s, source)
      |> Enum.map(fn [_, ddl] -> ddl end)
      |> Enum.find(fn ddl ->
        String.starts_with?(String.trim_leading(ddl), "CREATE TABLE " <> "\#{q(\"#{table}\")}")
      end)

    if is_nil(ddl), do: raise("generated table DDL is missing: #{table}")
    :ok = migrate_ddl!(c, ddl)

    if c[:hash_partitions] &&
         table in ["ash_onetime_idempotency_claims", "ash_onetime_nonce_claims"] do
      for remainder <- 0..(c.hash_partitions - 1) do
        Ecto.Adapters.SQL.query!(
          c.owner_repo,
          "CREATE TABLE \"#{c.schema}\".\"#{table}_p#{remainder}\" PARTITION OF \"#{c.schema}\".\"#{table}\" FOR VALUES WITH (MODULUS #{c.hash_partitions}, REMAINDER #{remainder})",
          []
        )
      end
    end

    if table == "ash_onetime_response_payloads" do
      Ecto.Adapters.SQL.query!(
        c.owner_repo,
        "CREATE TABLE \"#{c.schema}\".ash_onetime_response_payloads_default PARTITION OF \"#{c.schema}\".ash_onetime_response_payloads DEFAULT",
        []
      )
    end

    :ok
  end

  defp migrate_ddl!(c, ddl) do
    ceiling =
      if String.contains?(ddl, "@payload_ceiling"), do: "@payload_ceiling 16_777_216", else: ""

    qualifier =
      if String.contains?(ddl, "\#{q("),
        do: "defp q(name), do: ~s(\"\#{prefix()}\".\"\#{name}\")\n",
        else: ""

    source =
      "defmodule AshOnetime.Test.ConstraintFixture do\n" <>
        "use Ecto.Migration\n#{ceiling}\n" <>
        "def up do\nexecute(\"\"\"\n" <>
        ddl <>
        "\n\"\"\")\nend\n" <>
        qualifier <> "end\n"

    migrate!(c, source)
  end

  def migrate!(c, source, version \\ 1, direction \\ :up) do
    module = Module.concat(__MODULE__, "Migration#{System.unique_integer([:positive])}")

    source =
      Regex.replace(~r/defmodule [A-Za-z0-9_.]+ do/, source, "defmodule #{inspect(module)} do",
        global: false
      )

    [{^module, _}] = Code.compile_string(source)

    ExUnit.Callbacks.on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    previous = Repo.put_dynamic_repo(c.owner_repo)

    try do
      :ok =
        apply(Ecto.Migrator, direction, [Repo, version, module, [prefix: c.schema, log: false]])
    after
      Repo.put_dynamic_repo(previous)
    end
  end
end
