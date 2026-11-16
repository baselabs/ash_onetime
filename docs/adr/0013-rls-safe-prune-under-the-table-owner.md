# ADR 0013: RLS-safe prune under the table owner

Destructive emptiness decisions must see every tenant's rows or refuse. Partition age,
physical size, policy-filtered counts, and claim counts cannot establish safe emptiness.
Claim cleanup enforces retention; prune only reclaims expired, empty monthly tables.

The owner-owned prune routine checks trusted structure and READ COMMITTED isolation.
Within each child subtransaction it locks the parent first, then the child and DEFAULT
without waiting, and rechecks OID, parent membership, heap kind, and owner. Names remain
schema-qualified; fixed search paths put pg_temp last. One lock budget bounds the pass.

It temporarily removes FORCE and sets row_security=off, rechecks that FORCE stayed off,
and uses EXISTS over the child. The owner is exempt or the statement fails; policies
cannot turn occupied into empty. DROP requires proven emptiness. A kept/refused child
rolls back its subtransaction, restoring FORCE and releasing its locks. Caller row-security
settings are restored. Successful drops hold locks until the outer transaction ends.

Refused partitions do not undo successful claim/nonce cleanup. Kept counts include occupied
children; refusal counts and telemetry exclude ordinary occupancy. Isolation or trust failures
refuse maintenance before destructive work. Use bounded batches and short transactions.
`partition_limit: 0` disables partition DDL while retaining claim and nonce cleanup.

New children inherit the parent's ENABLE/FORCE flags and complete policy set. Their ACLs
remain owner-only, including column grants and grant options; runtime queries use the parent.

Existing installs generate and apply the operation-hold upgrade, then
`mix ash_onetime.gen.migrations --repo MyApp.Repo --maintenance --maintenance-role ROLE`.
Apply its migrations as the installation owner; schema-tenanted installs also use --tenants.
The declared maintenance role invokes owner-owned routines; it never gains table ownership
or a general RLS bypass. Check the live doctor per runtime role after migrating and run
`mix ash_onetime.roll_partitions --repo MyApp.Repo` to establish coverage.
