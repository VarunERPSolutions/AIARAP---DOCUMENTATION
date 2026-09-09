# inventory stack

The Postgres inventory writer (`modules/pg-inventory-writer`) that tracks
Tenant onboarding records into the app's own `global` schema (ADR-0004) —
not a competing schema.

**Extracted from `terraform/shared`** (2026-09-09) — it had zero
cross-references into that stack's Cognito/API Gateway/authorizer
resources (only plain input variables, `vpc_id`/`private_subnet_ids`, are
shared, and those are duplicated here rather than referenced across
state). Splitting it out means work on the Cognito/Gateway stack no longer
needs real `aiarap_db_*` values just to run a `plan`/`apply` that never
touches this concern. See
`docs/adr/0040-nine-cognito-pool-architecture.md`'s design discussion for
the reasoning.

## Required inputs

| Variable | Why it's not defaulted |
|---|---|
| `aiarap_db_instance_identifier`, `aiarap_db_name`, `aiarap_db_secret_arn` | RDS specifics not documented elsewhere — account-specific |

`aiarap_db_security_group_id` is optional (`null` by default) — set it to
have this stack wire the RDS-side ingress rule automatically, or leave it
unset and wire that ingress rule yourself.

## What this creates

- A security group for the pg-inventory-writer Lambda's ENIs (egress-only).
- `modules/pg-inventory-writer` itself, VPC-attached to reach the `aiarap`
  RDS instance.

## Output

- `inventory_writer_function_name` — feed into `terraform/tenants`'
  `inventory_writer_function_name` variable.
