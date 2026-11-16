# ADR 0004: Security-driven dependency floors

Published consumer requirements enforce patched minimums, independently of the development lock:

- Ash `>= 3.37.2 and < 4.0.0`;
- AshPostgres `~> 2.15 and >= 2.15.2`, AshSql `~> 0.8 and >= 0.8.6`;
- optional Igniter `~> 0.8 and >= 0.8.4`, Mint `~> 1.10 and >= 1.10.2`.

These floors cover authorization, tenant isolation, query-cache security, installer safety,
and HTTP memory-exhaustion/smuggling fixes. A lock update alone does not protect consumers.
Security-driven floor raises ship as minors with explicit upgrade instructions; non-security
raises require demonstrated compatibility. Breaking library DSL/API changes require a major.
