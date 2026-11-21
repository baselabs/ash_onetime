CREATE TABLE @schema@.ash_onetime_maintenance_runs (
  -- rule:maintenance-runs-primary-key
  step text PRIMARY KEY
    -- rule:maintenance-runs-check-step
    CHECK (step IN ('install','roll','cleanup','reap','prune')),
  installed_at timestamptz,
  last_success_at timestamptz,
  last_counts jsonb NOT NULL DEFAULT '{}',
  last_refusals jsonb NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
) USING heap
