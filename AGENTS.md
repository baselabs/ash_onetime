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

- **Where it runs.** Compile, tests, type checks and docs run in this repository's own GitHub Actions jobs on hosted runners. Each database job uses `.github/actions/postgres`. Platform lanes anonymously check `.github/postgres.ref` against infra's public current digest and start that immutable engine through `baselabs-test-postgres` as its PostgreSQL user. The compatibility matrix from `.github/postgres-compat.json` starts each declared upstream image by digest through its native entrypoint, with matching client tools; the platform major is excluded. `TEST_PG_USER`, `TEST_PG_PASSWORD` and `TEST_PG_DATABASE` explicitly create the throwaway fixture; TCP uses SCRAM, sockets use `/tmp`, and only loopback ports are published. The action also starts a dedicated logical server where required and removes both containers and their disposable storage under `if: always()`, logging failures. Agents never run these checks on a workstation or on shared build machines.
- Build: `mix compile --warnings-as-errors`.
- **Covering tests.** Every work-branch push runs `Work` on that head: the same Ash floor/latest, additional BEAM, security, release-gates and mutation job definitions as qualification, plus explicit quality, whole-suite platform PostgreSQL 18 and declared PostgreSQL 17 compatibility lanes, and both-cell lock checks (`DATABASE_URL` and `ASH_ONETIME_TEST_SERVER`; see `CONTRIBUTING.md`). Release gates execute all local Livebooks and optional consumers. Both committed locks (`mix.lock` and `locks/ash-floor/mix.lock`) must be current; the check resolves nothing. Resolve a lock with `mix deps.get` (with `ASH_ONETIME_ASH_VERSION` set to the floor for the floor cell) where `mix.exs` changes, and commit it with that change; resolving compiles nothing. Only the drift report resolves fresh from upstream. Never write lock entries by hand.
- **Type check.** `mix dialyzer` and `MIX_ENV=test mix dialyzer`, in the same CI run.
- **Release battery.** The additional release commands in `CONTRIBUTING.md` run in CI's release-gates job and
  its mutation-battery shard jobs. No job may measure over 45 minutes or carry a limit over 90; a
  longer job is split into jobs, never given a looser limit.
- **Caches.** Every job restores Mix caches through `.github/actions/mix-cache`; only the `Cache warmer`
  workflow on the default branch saves them.
- **Landing.** CI runs the full suite on a candidate branch before `main` moves. A work branch lands whole: merge `origin/main` into it, push it so `Work` runs on that head, then run the landing tool with `--sha <head>`, so that `main` moves to the branch's own commit. `--pick` copies commits and leaves the branch unmerged, so it is only for a commit that is not on a branch.

## CI/CD and releases

infra-1, the DevOps session, owns CI/CD, the build box, releases and their keys for every
product. Its requirements are binding here: the section "What infra requires of every product"
in `baselabs/docs/ci.md` of the infra repository, read from its default branch
(`git -C ~/Developer/infra fetch -q origin && git -C ~/Developer/infra show origin/main:baselabs/docs/ci.md`).
Re-read it whenever you touch a workflow, a Dockerfile, a release script or a secret.

- **Your part ends at the default branch.** Land only through the landing tool. Never release,
  deploy, publish, tag a version, dispatch a workflow, push an image by hand, or handle a
  release, publish or CI key. When something should go out, send infra-1 one message: the
  repository, the full commit, what goes out and anything it needs.
- **A landing ends with its cleanup.** A landing is not done until everything the change created
  is gone. In the same step that confirms the default branch moved, remove:
  - its work branch, on GitHub and locally (`git branch -d` succeeds, because the landed commits
    are on the default branch);
  - its worktree;
  - any Actions cache scoped to that branch;
  - every scratch ref, container, clone and temporary file it made.

  A branch that a rebuild replaces is deleted when the replacement is pushed, not when the
  replacement lands. The landing report lists what was removed. A child agent's final report
  lists every branch, ref, worktree, file and artifact it created, so the landing can remove
  them.
- **Publication.** Infra dispatches `publish.yml` on the qualified default-branch commit. It
  publishes only a new version of an existing Hex package, with a dated changelog section and
  no existing version tag. Build and inspect the package and docs archives before
  the keyed step; that step only uploads missing archives with `mix run --no-mix-exs` from an
  empty directory. A held release is finished by a second dispatch on the same commit after
  approval. Package bytes must match any staged or served release; retired releases are
  refused. Docs bytes are never compared: readable served docs are kept, missing docs uploaded.
  Every docs build writes root `release.json` with package, version and the run's commit.
  Keyless read-back requires `index.html` and that provenance naming this package and version
  and the dispatched commit or an ancestor on the default branch; it outputs that published
  commit. Only ready runs export `release-assets`: the package, downloaded served docs,
  recomputed checksums and checkout changelog notes, for infra to attach to the GitHub release
  on the published commit. A held run exports none. No archive is replaced. No workflow creates
  a release or runs on a tag. The `published-livebooks` job needs the publish job, uses the same
  actor restriction, and holds no environment or key. Qualification uses only local package consumers.
- **You write your own workflow changes; infra-1 reviews them.** Before landing a change to
  `.github/`, a Dockerfile, a release script or anything that touches a secret, send infra-1 the
  branch and head and wait for its review. Take any CI/CD, runner, box or key problem to
  infra-1, never around it.
- **The box.** This repository is public and never uses the build box or its runners. Never list
  process arguments (no `ps` with `args` or `-f`, no `/proc/*/cmdline`; use
  `ps -eo pid,etimes,pcpu,comm`). A secret never appears on a command line, in a log or in a
  message; report an exposed one to infra-1 by where it sits, never by its value. Nothing that
  compiles or tests runs on the owner's workstation.
- **Messages to infra-1:** one message per result, complete enough to act on without a reply.
  No acknowledgements and no status notes.
- Every brief given to a child agent carries these rules.
