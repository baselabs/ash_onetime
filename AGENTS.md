# Repository instructions

`ash_onetime` is a standalone Ash extension for explicit keyed-effect semantics.

## Boundaries

- Every protected action declares `:idempotency` or `:one_time_nonce`; there is no default strategy.
- Scope is explicit. Missing scope data is an error, never a global fallback.
- PostgreSQL is authoritative. Optional caches cannot grant admission.
- Nonce admission fails closed when authoritative state is unavailable.
- Idempotency may proceed when admission state is unavailable, but must surface that condition through telemetry.
- Verification callbacks return trusted local facts; action input cannot supply pre-verified facts.
- Do not depend on or name the reference projects listed (as digests) in `scripts/reference_projects.exs`.
- macOS and Linux are supported; Windows developers use WSL2, cloning inside its filesystem.
  CI runs on Linux; gates use Elixir (`.exs`) and `.gitattributes` preserves LF checkouts.

The lock and `.tool-versions` pin development releases; published ranges preserve supported floors.


## Build and test

- **Where it runs.** Compile, tests, type checks, docs and lock changes run in this repository's own GitHub Actions jobs on hosted runners, each with its own PostgreSQL 18 service container. Agents never run them on a workstation or on shared build machines.
- Build: `mix compile --warnings-as-errors`.
- **Covering tests.** Every push to a work branch runs the `Work` workflow on that head: the whole suite against PostgreSQL 18 (`DATABASE_URL` and `ASH_ONETIME_TEST_SERVER`; see `CONTRIBUTING.md`), the whole mutation battery and the lock check of both Ash cells' locks (`mix.lock` and `locks/ash-floor/mix.lock`), which uploads the resolved locks when a committed one is not current. Never write lock entries by hand.
- **Type check.** `mix dialyzer` and `MIX_ENV=test mix dialyzer`, in the same CI run.
- **Release battery.** The additional release commands in `CONTRIBUTING.md` run in CI's release-gates job.
- **Landing.** CI runs the full suite on a candidate branch before `main` moves.

## CI/CD and releases

infra-1, the DevOps session, owns CI/CD, the build box, releases and their keys for every
product. Its requirements are binding here: the section "What infra requires of every product"
in `baselabs/docs/ci.md` of the infra repository, read from its default branch
(`git -C ~/Developer/infra fetch -q origin && git -C ~/Developer/infra show origin/main:baselabs/docs/ci.md`).
Re-read it whenever you touch a workflow, a Dockerfile, a release script or a secret.

- **Your part ends at the default branch.** Land only through `kimosabe-land`. Never release,
  deploy, publish, tag a version, dispatch a workflow, push an image by hand, or handle a
  release, publish or CI key. When something should go out, send infra-1 one message: the
  repository, the full commit, what goes out and anything it needs.
- **You write your own workflow changes; infra-1 reviews them.** Before landing a change to
  `.github/`, a Dockerfile, a release script or anything that touches a secret, send infra-1 the
  branch and head and wait for its review. Take any CI/CD, runner, box or key problem to
  infra-1, never around it.
- **The box.** This repository is public and never uses the build box or its runners. Wherever
  the box is used: gate on `kimosabe-remote where` and your own routed run, never on `doctor`;
  never list process arguments (no `ps` with `args` or `-f`, no `/proc/*/cmdline`; use
  `ps -eo pid,etimes,pcpu,comm`). A secret never appears on a command line, in a log or in a
  message; report an exposed one to infra-1 by where it sits, never by its value. Nothing that
  compiles or tests runs on the owner's workstation.
- **Messages to infra-1:** one message per result, complete enough to act on without a reply.
  No acknowledgements and no status notes.
- Every brief given to a child agent carries these rules.
