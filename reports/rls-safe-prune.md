# RLS-safe payload prune — build report

**Release line for the owner (not run; publish awaits approval):**

```sh
git tag -a v1.9.0 -m "1.9.0" && git push origin main v1.9.0
env -u ASH_ONETIME_ASH_VERSION mix hex.publish --yes
```

Post-publish: verify hex.pm `latest_version` and the release's `requirements.ash.requirement`,
then `elixir scripts/check_livebooks.exs --published` with `DATABASE_URL` exported.

## What was built

`ash_onetime` 1.9.0: the payload-partition prune can no longer be fooled by row-level
security, and an opt-in dedicated prune path makes it correct under FORCE RLS.

- **Fail closed (always on).** `partition_empty?/2` now runs its counts with
  `SET LOCAL row_security = off` inside the cleanup transaction, so a policy that would
  filter the caller raises instead of silently shrinking the count. The prune refuses with
  the new `:row_security_blocked` code (503 in the errors table) and drops nothing — even
  when the filtered count happens to be right, it is never trusted. Consumers without RLS
  see identical behavior: no policy applies, nothing raises.
- **`--rls-prune --app-role NAME` (opt-in).** `mix ash_onetime.gen.migrations` renders
  `render_rls_prune/2` from a new template: a NOLOGIN role `ash_onetime_prune` created only
  if missing (owns no tables; the application role is never a member), a boolean
  `SECURITY DEFINER` emptiness function owned by that role with a fixed `search_path`
  (`EXECUTE` revoked from PUBLIC, granted to the application role; returns only the
  boolean), SELECT grants and a permissive `FOR SELECT` policy for the prune role on the
  claims and payload tables — and on every payload child partition, which are also brought
  in line with the parent's ENABLE/FORCE settings and full policy set.
- **Role-separation guards, in the migration itself.** The migrating role must differ from
  the application role (PostgreSQL 16+ gives a CREATEROLE creator ADMIN on the role, so a
  shared role could always `SET ROLE` and read every tenant). The migration refuses with a
  clear error when `current_user` is the application role, when that role holds SET, USAGE,
  or ADMIN (membership) on the prune role, and when creating the role needs CREATEROLE the
  migrating role lacks (superuser bootstrap is the documented alternative). It grants the
  migrating role `SET` on the prune role — just enough to transfer the function's
  ownership — and grants the prune role the schema CREATE that transfer requires, revoking
  it immediately after.
- **Children inherit at creation.** `roll_partitions`' `create_one_partition` now copies
  the parent's ENABLE/FORCE row-security settings, every parent policy the child lacks
  (the prune policy included), and grants the prune role SELECT on the new child — the
  same zero-argument dynamic DDL the migration uses (PostgreSQL 18's plpgsql parser
  rejects format/2 with text-typed declared variables in EXECUTE arguments, so the DDL is
  prebuilt and executed as one string).
- **The prune uses the function when it is installed** (probed per schema) and the
  fail-closed count when it is not. `DROP TABLE` needs table ownership, so under RLS the
  table owner drives cleanup; the function is what makes its counts trustworthy.

## Tests (red first, real PostgreSQL, non-superuser)

`test/ash_onetime/store/rls_prune_test.exs` — every prune runs over a connection whose
role is asserted to be neither superuser nor BYPASSRLS. Tier 1 (the defect and the
fail-closed refusal) runs on the shared instance's own non-superuser role; tier 2 (the
prune role, its function, and the refusals) creates fresh owner/application roles — it
self-bootstraps on a superuser/CREATEROLE substrate (CI, or an ephemeral area run with
`DATABASE_URL` pointed at it and `ASH_ONETIME_RLS_PRUNE_TESTS=1`) and skips with
instructions on the shared instance. On an ephemeral `postgres:18` run:

- RED before the fix: cleanup as tenant A under FORCE RLS dropped a partition holding
  only tenant B's payload, returning `{:ok, %{payload_partitions: 1}}`.
- GREEN: both tier-1 tests refuse with `:row_security_blocked` and drop nothing.
- With the function: an empty past-month partition drops; a partition holding only
  tenant B's rows survives and still reads 1 for tenant B.
- A child created by `roll_partitions` after the policies carries the parent's ENABLE +
  FORCE flags, both policies, the prune role's SELECT grant, and the function counts a
  tenant-B row in that child as non-empty — called as the application role.
- `pg_has_role(app, prune, SET/USAGE)` are false and no `pg_auth_members` row exists;
  `SET ROLE ash_onetime_prune` as the application role is denied.
- The migration refuses when run as the application role ("must not be the application
  role") and when that role holds SET ("SET, USAGE, or ADMIN"); in both cases the
  function is not left installed.

Full local battery before push: format, compile both envs warnings-as-errors, the full
`mix test` suite on the shared instance, credo --strict, dialyzer both envs,
deps.audit + hex.audit, docs --warnings-as-errors, cheat sheets, livebooks --local (all
four), the new mutation row RED→GREEN, `hex.build` + package consumer check.

## Not done / notes

- **Publishing waits for the owner** (release line above). The tag is not created.
- The migration's down drops the function, our policy, and our grants, and revokes the
  migrating role's SET — but leaves the `ash_onetime_prune` role itself in place: it is
  shared by name across installs, and a consumer's other schemas may still reference it.
- The committed boundary test-support migration and the fact-tables template are
  unchanged; the fact-table generator tests still cover their own prefix up/down path.
- ash_metered can drop its claims-only-cleanup workaround once this ships and it runs the
  `--rls-prune --app-role` migration with a dedicated migrating role.
