defmodule AshOnetime.Test.ExternalPeer do
  @moduledoc false

  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  @database_options [
    hostname: "127.0.0.1",
    port: 18_841,
    username: "postgres",
    password: "postgres",
    database: "ash_onetime_test"
  ]

  def install!(prefix) do
    prefix = validated_prefix!(prefix)

    with_connection(fn connection ->
      for table <- [
            "external_peer_calls",
            "external_peer_effects",
            "external_peer_operations",
            "external_local_effects"
          ] do
        Postgrex.query!(connection, "DROP TABLE IF EXISTS #{relation(prefix, table)} CASCADE", [])
      end

      Postgrex.query!(
        connection,
        "DROP FUNCTION IF EXISTS #{relation(prefix, "guard_external_ledgers")}() CASCADE",
        []
      )

      Postgrex.query!(
        connection,
        """
        CREATE TABLE #{relation(prefix, "external_peer_calls")} (
          event_id bigserial PRIMARY KEY,
          operation_key uuid NOT NULL,
          kind text NOT NULL CHECK (kind IN ('execute', 'recover')),
          inserted_at timestamptz NOT NULL DEFAULT statement_timestamp()
        )
        """,
        []
      )

      Postgrex.query!(
        connection,
        """
        CREATE TABLE #{relation(prefix, "external_peer_operations")} (
          operation_key uuid PRIMARY KEY,
          encoded_result bytea NOT NULL,
          inserted_at timestamptz NOT NULL DEFAULT statement_timestamp()
        )
        """,
        []
      )

      Postgrex.query!(
        connection,
        """
        CREATE TABLE #{relation(prefix, "external_peer_effects")} (
          event_id bigserial PRIMARY KEY,
          operation_key uuid NOT NULL,
          encoded_result bytea NOT NULL,
          inserted_at timestamptz NOT NULL DEFAULT statement_timestamp()
        )
        """,
        []
      )

      Postgrex.query!(
        connection,
        """
        CREATE TABLE #{relation(prefix, "external_local_effects")} (
          event_id bigserial PRIMARY KEY,
          operation_key uuid NOT NULL,
          value bigint NOT NULL,
          inserted_at timestamptz NOT NULL DEFAULT statement_timestamp()
        )
        """,
        []
      )

      Postgrex.query!(
        connection,
        """
        CREATE FUNCTION #{relation(prefix, "guard_external_ledgers")}()
        RETURNS trigger LANGUAGE plpgsql AS $guard$
        BEGIN
          RAISE EXCEPTION 'external evidence ledgers are append-only' USING ERRCODE = '23514';
        END
        $guard$
        """,
        []
      )

      for table <- ["external_peer_calls", "external_peer_effects", "external_local_effects"] do
        Postgrex.query!(
          connection,
          """
          CREATE TRIGGER #{table}_immutable
          BEFORE UPDATE OR DELETE ON #{relation(prefix, table)}
          FOR EACH ROW EXECUTE FUNCTION #{relation(prefix, "guard_external_ledgers")}()
          """,
          []
        )
      end
    end)
  end

  def execute(prefix, operation_key, result) do
    encoded = :erlang.term_to_binary(result, [:deterministic])
    with_connection(&execute_transaction(&1, prefix, operation_key, encoded))
  end

  defp execute_transaction(connection, prefix, operation_key, encoded) do
    {:ok, stored} =
      Postgrex.transaction(connection, fn transaction ->
        execute_in_transaction(transaction, prefix, operation_key, encoded)
      end)

    :erlang.binary_to_term(stored, [:safe])
  end

  defp execute_in_transaction(transaction, prefix, operation_key, encoded) do
    Postgrex.query!(
      transaction,
      "INSERT INTO #{relation(prefix, "external_peer_calls")} (operation_key, kind) VALUES ($1::uuid, 'execute')",
      [Ecto.UUID.dump!(operation_key)]
    )

    inserted =
      Postgrex.query!(
        transaction,
        """
        INSERT INTO #{relation(prefix, "external_peer_operations")}
          (operation_key, encoded_result)
        VALUES ($1::uuid, $2)
        ON CONFLICT DO NOTHING
        RETURNING encoded_result
        """,
        [Ecto.UUID.dump!(operation_key), encoded]
      )

    if inserted.num_rows == 1 do
      Postgrex.query!(
        transaction,
        "INSERT INTO #{relation(prefix, "external_peer_effects")} (operation_key, encoded_result) VALUES ($1::uuid, $2)",
        [Ecto.UUID.dump!(operation_key), encoded]
      )
    end

    %{rows: [[stored]]} =
      Postgrex.query!(
        transaction,
        "SELECT encoded_result FROM #{relation(prefix, "external_peer_operations")} WHERE operation_key = $1::uuid",
        [Ecto.UUID.dump!(operation_key)]
      )

    stored
  end

  def recover(prefix, operation_key, disposition \\ :authoritative) do
    with_connection(&recover_transaction(&1, prefix, operation_key, disposition))
  end

  defp recover_transaction(connection, prefix, operation_key, disposition) do
    {:ok, result} =
      Postgrex.transaction(connection, fn transaction ->
        recover_in_transaction(transaction, prefix, operation_key, disposition)
      end)

    result
  end

  defp recover_in_transaction(transaction, prefix, operation_key, disposition) do
    Postgrex.query!(
      transaction,
      "INSERT INTO #{relation(prefix, "external_peer_calls")} (operation_key, kind) VALUES ($1::uuid, 'recover')",
      [Ecto.UUID.dump!(operation_key)]
    )

    case disposition do
      :unknown ->
        :unknown

      :authoritative ->
        load_operation(transaction, prefix, operation_key)

      # A well-formed peer recovery that DIVERGES from what execute stored, used to prove that
      # finalize binds the recover result (the peer is authoritative for external effects).
      :divergent ->
        {:ok, 9_999}
    end
  end

  defp load_operation(transaction, prefix, operation_key) do
    case Postgrex.query!(
           transaction,
           "SELECT encoded_result FROM #{relation(prefix, "external_peer_operations")} WHERE operation_key = $1::uuid",
           [Ecto.UUID.dump!(operation_key)]
         ) do
      %{rows: [[encoded]]} -> {:ok, :erlang.binary_to_term(encoded, [:safe])}
      %{rows: []} -> :absent
    end
  end

  def calls(prefix),
    do:
      rows(
        prefix,
        "SELECT kind, operation_key::text FROM #{relation(prefix, "external_peer_calls")} ORDER BY event_id"
      )

  def count(prefix, table) do
    with_connection(fn connection ->
      %{rows: [[count]]} =
        Postgrex.query!(connection, "SELECT count(*) FROM #{relation(prefix, table)}", [])

      count
    end)
  end

  def append_local!(prefix, operation_key, value) do
    SQL.query!(
      Repo.get_dynamic_repo(),
      "INSERT INTO #{relation(prefix, "external_local_effects")} (operation_key, value) VALUES ($1::uuid, $2)",
      [Ecto.UUID.dump!(operation_key), value]
    )

    :ok
  end

  defp rows(_prefix, sql) do
    with_connection(fn connection ->
      %{rows: rows} = Postgrex.query!(connection, sql, [])
      rows
    end)
  end

  defp with_connection(callback) do
    {:ok, connection} = Postgrex.start_link(@database_options)
    Process.unlink(connection)

    try do
      callback.(connection)
    after
      if Process.alive?(connection), do: GenServer.stop(connection, :normal, 5_000)
    end
  end

  defp relation(prefix, table), do: ~s("#{validated_prefix!(prefix)}"."#{table}")

  defp validated_prefix!(prefix) when is_binary(prefix) do
    if Regex.match?(~r/\A[a-zA-Z0-9_]+\z/, prefix), do: prefix, else: raise("invalid test prefix")
  end
end
