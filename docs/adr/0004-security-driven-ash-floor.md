# ADR 0004: Security-driven dependency floors

Published consumer requirements enforce patched minimums, independently of the development lock:

- Ash `>= 3.38.1 and < 4.0.0`;
- AshPostgres `~> 2.15 and >= 2.15.2`, AshSql `~> 0.8 and >= 0.8.6`;
- DBConnection `~> 2.10 and >= 2.10.3`;
- optional Igniter `~> 0.8 and >= 0.8.4`, Mint `~> 1.10 and >= 1.10.2`.

These floors cover authorization, pagination cursor security, keyword input validation, tenant
isolation, query-cache security, stream logging, installer safety, and HTTP memory exhaustion
and response smuggling.
A lock update alone does not protect consumers.
Security-driven floor raises ship as minors with explicit upgrade instructions; non-security
raises require demonstrated compatibility. Breaking library DSL/API changes require a major.

## November 24, 2026 amendment

The minimum Ash version rose from 3.37.2 to 3.38.0 to address
[GHSA-m5v6-3qwf-6w9r (CVE-2026-124283)](https://github.com/ash-project/ash/security/advisories/GHSA-m5v6-3qwf-6w9r),
which affects Ash `>= 3.31.3 and < 3.38.0`. The fix prevents code execution and SQL
injection through forged keyset pagination cursors. Both committed locks must resolve to
patched Ash releases.

## November 24, 2026 amendment — keyword input validation

The minimum Ash version rose from 3.38.0 to 3.38.1 to address
[EEF-CVE-2026-120299 (GHSA-rwmx-99mc-qr2x)](https://cna.erlef.org/osv/EEF-CVE-2026-120299.html),
which affects Ash `>= 3.24.0 and < 3.38.1`. The fix makes `Ash.Type.Keyword` validate each
field through its input cast when handling client input.

## November 24, 2026 amendment — DBConnection stream logging

Declare a DBConnection floor of `~> 2.10 and >= 2.10.3` for
[EEF-CVE-2026-133555 (GHSA-gmmq-fw75-wq46)](https://cna.erlef.org/osv/EEF-CVE-2026-133555.html),
which affects releases `>= 1.1.0 and < 2.10.3`. Postgrex and Ecto SQL already bring DBConnection
into the dependency graph. The explicit requirement protects every consumer's resolution, and
both committed locks must also resolve to patched releases.
