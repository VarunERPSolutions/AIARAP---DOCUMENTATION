# Customer onboarding Terraform

`modules/customer-onboarding` provisions everything one customer needs for
flows 1 & 3 (Customer Salesforce/SAP → Node/Java): per-customer TLS, API
Gateway routing, and per-customer-per-backend-per-environment OAuth
credentials + API keys. `customers/` is the root config that calls the module
once per customer from a single list.

## What the module creates, per customer

- ACM certificate covering `custXX.aiarap.com` (prod) + `*.custXX.aiarap.com`
  (dev/qa) — two SANs on one cert, DNS-validated.
- **One API Gateway custom domain per environment** (bare apex = prod,
  `dev.`/`qa.` prefix = non-prod — three domain objects, not apex+wildcard),
  each base-path-mapped to that backend's REST API (`var.api_ids["node"]`,
  `var.api_ids["java"]`) **and that environment's stage** — dev and qa route
  to different stages of the same API (node-app/java-app dev and qa run as
  separate containers even when they share an instance, see
  `docker/README.md`), and a base-path mapping can't pick a stage based on
  which subdomain was hit, so a single wildcard domain object can't cover
  both anymore. Environment resolution happens via the stage itself
  (`requestContext.stage`) at the shared Lambda authorizer, not the Host
  header.
- One Cognito app client (client-credentials grant) per connection ×
  environment, each restricted to exactly one scope
  (`<backend>.invoke.<env>`) — this is the actual per-customer-per-backend-
  per-environment isolation boundary.
- One Secrets Manager secret per connection, bundling the token URL, client
  ID/secret, scope, API key, and the host/path the customer should call.
- One API key + usage plan per connection, for independent per-connection
  throttling/quota — **not** an auth mechanism, just metering/rate-limiting.
- One inventory row per connection, upserted into the aiarap RDS Postgres
  instance via the shared `pg-inventory-writer` Lambda (Terraform has no VPC
  reachability to aiarap RDS directly). Cognito clients and API keys aren't
  taggable, so this is the source of truth for "who owns which credential" —
  and unlike the DynamoDB approach this replaces, removing a connection
  actually deletes its row (via `lifecycle_scope = "CRUD"`), not just leaves
  it orphaned.

Default customer = 3 connection types (`sf-node`, `sap-node`, `sap-java`) × 3
environments (`dev`, `qa`, `prd`) = 9 connections. Override `connections` or
`environments` per customer in `customers/terraform.tfvars` to onboard a
customer with a different shape (see `terraform.tfvars.example`).

## Prerequisites — created once, NOT by this module

These must exist before onboarding any customer, and their IDs are passed in
as variables (ideally via remote state, not hardcoded):

1. **Cognito User Pool** with a custom domain (`auth.varunerpsolutions.com`)
   and three resource servers already defined:
   - `node-api` (`https://api.aiarap.com/node`) — scopes `node.invoke.dev`,
     `node.invoke.qa`, `node.invoke.prd`
   - `java-api` (`https://api.aiarap.com/java`) — scopes `java.invoke.dev`,
     `java.invoke.qa`, `java.invoke.prd`
   - `sap-api` (`https://api.varunerpsolutions.com/sap`) — scopes
     `sap.invoke.dev`, `sap.invoke.prd` (used by the separate
     VarunERP-internal Salesforce→SAP connection, not by this module)
2. **Three REST APIs, one per backend** (`node`, `java`, `sap`) — each with
   one deployment and one **stage per environment** (a stage-variable-driven
   integration URI, not a separate API per environment — see
   `terraform/shared/README.md`), wired via VPC Link to node-app/java-app/
   the SAP tailnet-proxy, and the same shared `modules/lambda-authorizer`
   attached to all three. The Lambda resolves backend from `apiId` and
   environment directly from `requestContext.stage` — no Host-header
   parsing at all.
3. **Route53 hosted zone** for `aiarap.com`.
4. **`modules/pg-inventory-writer`**, deployed once — a VPC-attached Lambda
   that upserts/deletes inventory rows in a new `integration_inventory`
   schema inside the existing **aiarap RDS Postgres** instance (the schema
   and its two tables, `customers` and `connections`, are created
   automatically on first apply — no manual migration step). Requires:
   - a Postgres role with rights to create/use that schema, credentials in a
     Secrets Manager secret (`{"username":..., "password":...}` — host/port/
     db name are passed as separate Terraform variables, not read from the
     secret)
   - the Lambda's security group allowed inbound on 5432 by aiarap RDS's
     security group
   - the Terraform-runner's IAM identity needs `lambda:InvokeFunction` on
     this function, in addition to whatever it already needs to manage the
     other resources here

## Onboarding a new customer

Add a row to `customers` in `customers/terraform.tfvars`, then
`terraform apply` in `customers/`. Offboarding is the reverse: remove the row
and apply — this tears down that customer's certs, domains, Cognito clients,
API keys, and secrets, but leaves every other customer untouched.

## Not covered here

- Flow 2 (VarunERP Salesforce → VarunERP SAP) — single internal connection,
  not per-customer; provision its one Cognito client + secret directly
  against the shared pool.
- mTLS/Private CA — only needed if a specific customer's security policy
  requires client certs instead of OAuth; not part of the default onboarding
  path.
