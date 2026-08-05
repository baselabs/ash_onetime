# Security policy

Please report suspected vulnerabilities privately to the maintainers through GitHub's
private vulnerability reporting for `baselabs/ash_onetime`. Do not open a public issue
until a maintainer confirms disclosure is safe.

Supported releases will be listed here after the first public release. Until then,
security fixes apply to the current `main` branch.

Reports should include the affected commit or release, a minimal reproduction, impact,
and whether the issue concerns scope isolation, admission uncertainty, replay,
cryptography, response persistence, or cleanup.

Security invariants include mandatory explicit scope, PostgreSQL-only admission authority,
fail-closed nonce uncertainty, digest- and contract-bound response replay, trusted-local-only
verification facts, strict post-horizon cleanup, and conservative external recovery. Optional
caches, Plug extraction, and Oban scheduling cannot grant admission.

Do not include production keys, tokens, signatures, response payloads, tenant data, or database
credentials in a report. Use synthetic evidence and coordinate encrypted transfer if a secret
is essential to reproduction. See [the security model](documentation/security.md) for trust
boundaries and named misuses.
