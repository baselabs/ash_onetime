<%
reference_legacy = Keyword.get(binding(), :reference_legacy, false)
maintenance = Keyword.get(binding(), :maintenance, true)
external_claim_columns = EEx.eval_file(Path.join([__DIR__, "external_state", "claims.sql"]), fragment: (if reference_legacy, do: :legacy_columns, else: :columns))
external_claim_checks = EEx.eval_file(Path.join([__DIR__, "external_state", "claims.sql"]), fragment: (if reference_legacy, do: :legacy_checks, else: :checks))
install_source = File.read!(Path.join(__DIR__, "install.exs"))
reference_statements = Regex.scan(~r/execute\("""\n(.*?)\n    """\)/s, install_source)
  |> Enum.map(fn [_, ddl] -> String.trim(ddl) end)
  |> Enum.filter(fn ddl -> String.starts_with?(ddl, "CREATE INDEX") or Regex.match?(~r/^CREATE TABLE #\{q\("ash_onetime_(idempotency_claims|nonce_claims|response_payloads)"\)\}/, ddl) end)
  |> Enum.flat_map(fn ddl ->
    for hash <- [nil, 1] do
    ddl = EEx.eval_string(ddl, hash_partitions: hash, external_claim_columns: external_claim_columns, external_claim_checks: external_claim_checks, collision_constraint: "UNIQUE (logical_partition, operation_hash, scope_hash, key_hash)")
    ddl = Regex.replace(~r/#\{q\("([^"]+)"\)\}/, ddl, fn _, name -> "@schema@." <> inspect(name) end)
    ddl = String.replace(ddl, "#" <> "{@payload_ceiling}", "16777216")
    [_, root] = Regex.run(~r/ash_onetime_(idempotency_claims|nonce_claims|response_payloads)/, ddl)
    {"ash_onetime_" <> root <> (if hash && root in ["idempotency_claims", "nonce_claims"], do: "_hash", else: ""), ddl}
    end
  end)
  |> Enum.uniq()
reference_ddl = Enum.group_by(reference_statements, &elem(&1,0), &elem(&1,1))
runs_ddl = File.read!(Path.join([__DIR__, "maintenance", "runs.sql"]))
reference_ddl = Map.put(reference_ddl, "ash_onetime_maintenance_runs", [runs_ddl])
reference_ddl = if reference_legacy, do: reference_ddl, else: Map.put(reference_ddl, "ash_onetime_effect_outcomes", [EEx.eval_file(Path.join([__DIR__, "external_state", "outcomes.sql"]), fragment: :ddl)])
reference_ddl = reference_ddl |> Enum.sort() |> Enum.map_join("\n", fn {name, statements} ->
    "WHEN '" <> name <> "' THEN '" <> (Enum.join(statements,";") |> String.replace("'","''")) <> "'"
  end)
routine_attributes = Map.new([:top_level, :inside, :definer, :invoker], fn fragment ->
  {fragment, EEx.eval_file(Path.join([__DIR__, "maintenance", "settings.sql"]), fragment: fragment) |> String.trim()}
end)
functions = [
  {"ash_onetime_cleanup_eligible", "retain_until timestamptz", "boolean", "eligible", false},
  {"ash_onetime_guard_idempotency_delete", "", "trigger", "guard_idempotency", false},
  {"ash_onetime_guard_idempotency_update", "", "trigger", "../external_state/claims", false},
  {"ash_onetime_guard_effect_outcome", "", "trigger", "outcomes_guard", false},
  {"ash_onetime_bound_effect_outcome", "", "trigger", "outcomes_bound", false},
  {"ash_onetime_claim_visible", "claim_operation bytea, claim_partition text, claim_uuid uuid", "boolean", "outcomes_visible", false},
  {"ash_onetime_guard_nonce_delete", "", "trigger", "guard_nonce", false},
  {"ash_onetime_maintenance_active", "", "boolean", "active", false},
  {"ash_onetime_maintenance_relations", "", "SETOF oid", "relations", false},
  {"ash_onetime_maintenance_policy_error", "", "text", "policy", false},
  {"ash_onetime_maintenance_reset_acl", "relation_oid oid, owner_only boolean", "void", "reset_acl", false},
  {"ash_onetime_maintenance_copy_policy", "child_oid oid", "void", "copy_policy", false},
  {"ash_onetime_maintenance_lock", "exclusive_parent boolean, budget_ms integer", "void", "lock", false},
  {"ash_onetime_maintenance_edges", "class_oid oid, object_oid oid", "TABLE(classid oid, objectid oid, kind text)", "edges", false},
  {"ash_onetime_maintenance_normalize", "tree text, relation_oid oid", "text", "normalize", false},
  {"ash_onetime_maintenance_shape", "relation_oid oid", "jsonb", "shape", false},
  {"ash_onetime_maintenance_capture", "", "jsonb", "capture", false},
  {"ash_onetime_maintenance_reference", "legacy_mode boolean", "jsonb", "reference", false},
  {"ash_onetime_maintenance_shapes", "", "jsonb", "shapes", false},
  {"ash_onetime_maintenance_trust", "", "void", "trust", false},
  {"ash_onetime_maintenance_acl", "", "boolean", "acl", false},
  {"ash_onetime_expire_responses", "batch_size integer", "bigint", "expire", true},
  {"ash_onetime_cleanup_idempotency", "batch_size integer", "bigint", "cleanup_idempotency", true},
  {"ash_onetime_cleanup_nonce", "batch_size integer", "bigint", "cleanup_nonce", true},
  {"ash_onetime_reap_idempotency", "batch_size integer, abandonment_seconds bigint", "bigint", "reap", true},
  {"ash_onetime_prune_payload_partitions", "partition_limit integer, lock_budget_ms integer", "jsonb", "prune", true},
  {"ash_onetime_roll_payload_partitions", "months_ahead integer", "bigint", "roll", true},
  {"ash_onetime_maintenance_status", "", "jsonb", "status", true}
] |> Enum.map(fn {name,args,result,file,definer} ->
  %{name: name, args: args, grant_class: (cond do name == "ash_onetime_guard_effect_outcome" -> :guard; name == "ash_onetime_claim_visible" -> :public_invoker; definer -> :step; true -> :invoker end), settings_class: (cond do name == "ash_onetime_guard_effect_outcome" -> :inside_guard; name in ["ash_onetime_cleanup_eligible", "ash_onetime_guard_idempotency_delete", "ash_onetime_guard_nonce_delete", "ash_onetime_guard_idempotency_update", "ash_onetime_bound_effect_outcome", "ash_onetime_claim_visible", "ash_onetime_maintenance_active" ] -> :inside; true -> :top_level end), security: (cond do name == "ash_onetime_guard_effect_outcome" -> EEx.eval_file(Path.join([__DIR__, "external_state", "outcomes.sql"]), fragment: :guard_security) |> String.trim(); name == "ash_onetime_bound_effect_outcome" -> EEx.eval_file(Path.join([__DIR__, "external_state", "outcomes.sql"]), fragment: :bound_security) |> String.trim(); definer -> routine_attributes.definer; true -> routine_attributes.invoker end), settings: (cond do name == "ash_onetime_guard_effect_outcome" -> EEx.eval_file(Path.join([__DIR__, "external_state", "outcomes.sql"]), fragment: :guard_settings) |> String.trim(); name == "ash_onetime_bound_effect_outcome" -> EEx.eval_file(Path.join([__DIR__, "external_state", "outcomes.sql"]), fragment: :bound_settings) |> String.trim(); name == "ash_onetime_claim_visible" -> EEx.eval_file(Path.join([__DIR__, "external_state", "outcomes.sql"]), fragment: :visible_settings) |> String.trim(); name in ["ash_onetime_cleanup_eligible", "ash_onetime_guard_idempotency_delete", "ash_onetime_guard_nonce_delete", "ash_onetime_guard_idempotency_update", "ash_onetime_maintenance_active"] -> routine_attributes.inside; true -> routine_attributes.top_level end), language: (if name == "ash_onetime_claim_visible", do: "sql", else: "plpgsql"), types: (args |> String.split(",", trim: true) |> Enum.map(&(String.split(&1) |> List.last())) |> Enum.join(",")), result: result, body: (if file == "../external_state/claims", do: EEx.eval_file(Path.join([__DIR__, "external_state", "claims.sql"]), fragment: :trigger), else: (if String.starts_with?(file, "outcomes_"), do: EEx.eval_file(Path.join([__DIR__, "external_state", "outcomes.sql"]), fragment: String.replace_prefix(file,"outcomes_","") |> String.to_atom()), else: EEx.eval_file(Path.join([__DIR__,"maintenance",(if file == "reference" and reference_legacy, do: "reference_legacy", else: file) <> ".sql"]), maintenance: maintenance, include_outcomes: not reference_legacy))) |> String.replace("@reference_ddl@", String.replace(reference_ddl,"@schema@","__package_schema__"))}
end)
only = Keyword.get(binding(), :only) %>
<%= inspect(Enum.filter(functions, fn routine -> is_nil(only) or routine.name in only end), limit: :infinity, printable_limit: :infinity) %>
