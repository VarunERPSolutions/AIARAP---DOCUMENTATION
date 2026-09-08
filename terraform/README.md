# Tenant onboarding Terraform

`modules/tenant-onboarding` provisions everything one Tenant needs for
inbound integration (Tenant Salesforce/SAP → Node): per-Tenant TLS, API
Gateway routing, and per-Tenant-per-backend-per-environment OAuth
credentials + API keys. `tenants/` is the root config that calls the module
once per Tenant from a single list — keyed by `subdomain`, the same value
as `global.tenant_registry.subdomain` in the app's own schema.

Java is **not** part of this module — see `shared/java_outbound.tf` and its
header comment. Per [ADR-0039](../docs/adr/0039-sap-integration-technology-and-backend-stack.md),
Java/Spring Batch is a nightly outbound-only worker (it calls out to each
Tenant's SAP system; it never receives an inbound call), so it has no
Tenant-facing API, Cognito scope, or per-Tenant onboarding step at all.

## What the module creates, per Tenant

- ACM certificate covering `{subdomain}.aiarap.com` (prod) +
  `*.{subdomain}.aiarap.com` (dev/qa) — two SANs on one cert, DNS-validated.
- **One API Gateway custom domain per environment** (bare apex = prod,
  `dev.`/`qa.` prefix = non-prod — three domain objects, not apex+wildcard),
  each base-path-mapped to that backend's REST API (`var.api_ids["node"]`)
  **and that environment's stage** — dev and qa route to different stages
  of the same API (node-app's dev and qa run as separate containers even
  when they share an instance, see `docker/README.md`), and a base-path
  mapping can't pick a stage based on which subdomain was hit, so a single
  wildcard domain object can't cover both anymore. Environment resolution
  happens via the stage itself (`requestContext.stage`) at the shared
  Lambda authorizer, not the Host header.
- One Cognito app client (client-credentials grant) per connection ×
  environment, each restricted to exactly one scope
  (`<backend>.invoke.<env>`) — this is the actual per-Tenant-per-backend-
  per-environment isolation boundary.
- One Secrets Manager secret per connection, bundling the token URL, client
  ID/secret, scope, API key, and the host/path the Tenant should call.
- One API key + usage plan per connection, for independent per-connection
  throttling/quota — **not** an auth mechanism, just metering/rate-limiting.
- One inventory row per connection, upserted into the aiarap RDS Postgres
  instance's `global` schema via the shared `pg-inventory-writer` Lambda
  (Terraform has no VPC reachability to aiarap RDS directly). Cognito
  clients and API keys aren't taggable, so this is the source of truth for
  "who owns which credential" — and removing a connection actually deletes
  its row (via `lifecycle_scope = "CRUD"`), not just leaves it orphaned.

Default Tenant = 2 connection types (`sf-node`, `sap-node`) × 3 environments
(`dev`, `qa`, `prd`) = 6 connections. Override `connections` or
`environments` per Tenant in `tenants/terraform.tfvars` to onboard a Tenant
with a different shape (see `terraform.tfvars.example`).

## Prerequisites — created once, NOT by this module

These must exist before onboarding any Tenant, and their IDs are passed in
as variables (ideally via remote state, not hardcoded):

1. **Cognito User Pool** with a custom domain (`auth.varunerpsolutions.com`)
   and two resource servers already defined:
   - `node-api` (`https://api.aiarap.com/node`) — scopes `node.invoke.dev`,
     `node.invoke.qa`, `node.invoke.prd`
   - `sap-api` (`https://api.varunerpsolutions.com/sap`) — scopes
     `sap.invoke.dev`, `sap.invoke.prd` (used by the separate
     VarunERP-internal Salesforce→SAP connection, not by this module)
2. **Two REST APIs, one per backend** (`node`, `sap`) — each with one
   deployment and one **stage per environment** (a stage-variable-driven
   integration URI, not a separate API per environment — see
   `terraform/shared/README.md`), wired via VPC Link to node-app/the SAP
   tailnet-proxy, and the same shared `modules/lambda-authorizer` attached
   to both. The Lambda resolves backend from `apiId` and environment
   directly from `requestContext.stage` — no Host-header parsing at all.
3. **Route53 hosted zone** for `aiarap.com`.
4. **`modules/pg-inventory-writer`**, deployed once — a VPC-attached Lambda
   that upserts/deletes inventory rows into the app's own **`global`
   schema** (ADR-0004 — deliberately not a competing schema, since this is
   AIARAP-internal governance metadata, not Tenant business data) inside
   the existing **aiarap RDS Postgres** instance (the `integration_connection`
   table is created automatically on first apply — no manual migration
   step). Requires:
   - a Postgres role with rights to create/use that schema, credentials in a
     Secrets Manager secret (`{"username":..., "password":...}` — host/port/
     db name are passed as separate Terraform variables, not read from the
     secret)
   - the Lambda's security group allowed inbound on 5432 by aiarap RDS's
     security group
   - the Terraform-runner's IAM identity needs `lambda:InvokeFunction` on
     this function, in addition to whatever it already needs to manage the
     other resources here

## Onboarding a new Tenant

Add a row to `tenants` in `tenants/terraform.tfvars`, then `terraform apply`
in `tenants/`. Offboarding is the reverse: remove the row and apply — this
tears down that Tenant's certs, domains, Cognito clients, API keys, and
secrets, but leaves every other Tenant untouched.

## Not covered here

- Flow 2 (VarunERP Salesforce → VarunERP SAP) — single internal connection,
  not per-Tenant; provision its one Cognito client + secret directly
  against the shared pool (see `shared/flow2.tf`).
- Java's outbound extraction infrastructure — see `shared/java_outbound.tf`.
- mTLS/Private CA — only needed if a specific Tenant's security policy
  requires client certs instead of OAuth; not part of the default onboarding
  path.
