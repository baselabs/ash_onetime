defmodule AshOnetime.Test.Migration do
  @moduledoc false

  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  def assert_isolated_database! do
    %{rows: [[database, port, server_version]]} =
      SQL.query!(
        Repo,
        "SELECT current_database(), current_setting('port'), current_setting('server_version')",
        []
      )

    unless database == "ash_onetime_test" and port == "5432" and
             String.starts_with?(server_version, "18.") do
      raise "database isolation check failed"
    end

    :ok
  end

  def with_sql(up_sql, down_sql, callback) when is_function(callback, 0) do
    SQL.query!(Repo, up_sql, [])

    try do
      callback.()
    after
      SQL.query!(Repo, down_sql, [])
    end
  end
end
