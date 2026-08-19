# Security policy

Please report suspected vulnerabilities privately to the maintainers through GitHub's
private vulnerability reporting for `baselabs/ash_onetime`. Do not open a public issue
until a maintainer confirms disclosure is safe.

## Supported versions

| Release line | Bug fixes | Security fixes |
| --- | --- | --- |
| Pre-1.0: latest published minor (currently `0.7.x`) | Yes | Yes |
| Pre-1.0: older minors | No | No — upgrade to the latest minor |
| From 1.0.0: latest minor | Yes | Yes |
| From 1.0.0: previous minor | Security-driven only | Yes — backported patch releases |

From 1.0.0 the security window covers the latest two minors. The window may widen
(announced as a docs change) and never silently narrows — a narrowing is announced one
minor ahead in the release notes.

## Fix and disclosure policy

- Security fixes ship as patch releases on the supported minors. A fix that takes the
  form of a dependency-floor raise (the v0.7.0 class) follows the floor policy: a minor
  on the latest line, plus — once 1.0.0 splits the window — a patch backport carrying
  only the floor raise on the second supported minor. Fix development happens in the
  advisory's private collaboration space; the advisory is published when the patches are
  out.
- A vulnerable dependency floor is a security issue of this package. The published
  requirement range is part of ash_onetime's security surface — a security library must
  not resolve to a vulnerable floor. Dependency advisories that affect a supported
  minor's resolvable range get the same intake, severity, and backport handling as
  direct defects.
- Advisories publish as GitHub Security Advisories (GHSA; CVE IDs via GitHub's CNA) and
  are linked from the CHANGELOG entry of the fixing release. Reporters are credited by
  name unless they decline.
- No hard SLA and no automatic disclosure deadline: private reports are acknowledged
  within 7 days, receive status updates at least weekly while open, and publish
  cooperatively with the reporter. Mitigations and workarounds are published first when
  a fix needs longer.

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
