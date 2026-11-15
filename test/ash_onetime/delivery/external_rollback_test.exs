defmodule AshOnetime.Delivery.ExternalRollbackTest do
  use AshOnetime.Test.StoreCase, async: false

  import AshOnetime.Test.DeliveryCase

  alias AshOnetime.Delivery
  alias AshOnetime.Test.ExitBoundary.{Faults, Withheld}
  alias AshOnetime.Test.ExternalPeer

  @moduletag unboxed: true
  @moduletag executing_only_external_rollback: true

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    ExternalPeer.install!(prefix)
    SQL.query!(Repo, ~s[CREATE TABLE IF NOT EXISTS "#{prefix}".ash_onetime_boundary_records (id uuid PRIMARY KEY, amount bigint NOT NULL, retired boolean NOT NULL DEFAULT false)], [])
    peer = start_supervised!({Postgrex, ExternalPeer.database_options()})
    Faults.put_peer(peer)
    Repo.put_dynamic_repo(start_unboxed_repo!(prepare: :unnamed))
    :ok
  end

  for {route, action} <- [create: :external_issue, update: :external_rotate,
                          destroy: :external_revoke, soft_destroy: :external_retire,
                          generic: :external_mint] do
    @route route
    @action action
    test "#{route}: external commit survives rollback and a success hook never delivers it", %{prefix: prefix} do
      key = unique_key("external-rollback")
      record = if @route in [:update, :destroy, :soft_destroy],
        do: AshOnetime.Test.ExitBoundary.Pair.seed!(Withheld, prefix)
      path = %AshOnetime.Test.ExitBoundary.Pair.Path{
        type: if(@route == :generic, do: :action, else: if(@route == :soft_destroy, do: :destroy, else: @route)),
        action: @action, key: key, input: case @route do
          :generic -> %{value: 7}
          route when route in [:create, :update] -> %{amount: 7}
          _ -> %{}
        end}
      build = fn -> AshOnetime.Test.ExitBoundary.Pair.subject(path, Withheld, prefix, record) end
      Process.put(:fail_external_completion, true)

      first = build.() |> fail_after_completion(:fail_external_completion) |> recover_errors() |> AshOnetime.deliver()
      assert Process.get(:fail_external_completion) == nil, "the action must reach completed execution before rollback"
      assert error_code(first) == :executing_only_lost
      assert peer_counts(prefix) == {1, 0, 1}
      assert %{rows: [["processing"]]} = SQL.query!(Repo, ~s[SELECT c.state FROM "#{prefix}".ash_onetime_idempotency_claims c JOIN "#{prefix}".external_peer_operations p ON p.operation_key = c.id], [])

      retry = AshOnetime.deliver(build.())
      assert %Delivery{outcome: :recovered, values: values} = elem(retry, tuple_size(retry) - 1)
      assert map_size(values) == 0
      assert peer_counts(prefix) == {1, 1, 1}
      assert %{rows: [["complete"]]} = SQL.query!(Repo, ~s[SELECT c.state FROM "#{prefix}".ash_onetime_idempotency_claims c JOIN "#{prefix}".external_peer_operations p ON p.operation_key = c.id], [])
    end
  end

  defp peer_counts(prefix) do
    %{rows: [[executed, recovered, effects]]} = SQL.query!(Repo,
      ~s[SELECT (SELECT count(*) FROM "#{prefix}".external_peer_calls WHERE kind = 'execute'), (SELECT count(*) FROM "#{prefix}".external_peer_calls WHERE kind = 'recover'), (SELECT count(*) FROM "#{prefix}".external_peer_effects)], [])
    {executed, recovered, effects}
  end
end
