for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.ArgumentGuardsTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning

    for {rule, name, arguments, message} <- [
      {"cleanup-idempotency-arguments", "ash_onetime_cleanup_idempotency", "NULL", "invalid cleanup batch size"},
      {"cleanup-nonce-arguments", "ash_onetime_cleanup_nonce", "NULL", "invalid cleanup batch size"},
      {"expire-arguments", "ash_onetime_expire_responses", "NULL", "invalid expiry batch size"},
      {"reap-batch-arguments", "ash_onetime_reap_idempotency", "NULL,86400", "invalid reap batch size"},
      {"reap-horizon-arguments", "ash_onetime_reap_idempotency", "1,NULL", "invalid reap abandonment horizon (86400..315576000000 seconds)"},
      {"prune-arguments", "ash_onetime_prune_payload_partitions", "NULL,100", "invalid prune bounds"}
    ] do
      @name name
      @arguments arguments
      @message message
      @tag [{String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}]
      test "#{partitioning || "plain"}: #{@name} refuses #{@arguments}", c do
        assert {:error, %Postgrex.Error{postgres: %{pg_code: "22023", message: @message}}} = step(c, @name, @arguments)
      end
    end
  end
end
