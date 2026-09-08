# Infrastructure reference

Merged in from the standalone `VarunERP_Network` project (Tailscale employee
access + the customer integration hub), then reconciled against this
project's own ADRs/schema docs.

- `INFRASTRUCTURE_REFERENCE.md` — AWS + Tailscale employee access, plus a
  summary of the Tenant integration hub (§11) pointing at `terraform/` and
  `docker/` at the repo root.
- `architecture-diagram.html` — the visual, rebuilt to match: Figure 1
  (Tailscale/employee access), Figure 2 (Tenant integration hub — 2 inbound
  REST APIs, Tenant terminology), Figure 3 (Java's nightly outbound
  extraction to each Tenant's SAP system, kept as its own figure rather than
  mixed into Figure 2, since it's the opposite direction of every other
  arrow there), and a three-call request walkthrough reflecting the
  corrected routing (both Node examples now share one apiId, differing only
  by stage).

## Conflicts found against this project's ADRs/schema — resolved in `terraform/`

1. **Terminology** ✅ resolved. Renamed throughout: `customer_id` →
   `subdomain` (matching `global.tenant_registry.subdomain`),
   `modules/customer-onboarding` → `modules/tenant-onboarding`,
   `terraform/customers` → `terraform/tenants`, "customer" → "Tenant" in
   every description/comment.
2. **Schema-per-tenant (ADR-0004)** ✅ resolved. `pg-inventory-writer` now
   writes into the app's own **`global` schema**, one table
   (`global.integration_connection`), not a competing `integration_inventory`
   schema with its own parallel `customers`/`connections` tables.
   `tenant_subdomain` is a plain column, deliberately **not** a foreign key
   into `global.tenant_registry` — that table is owned/migrated by the main
   app, not this Lambda, and FK'ing into it would create a migration-
   ordering dependency between two separately-deployed projects. Same
   natural key (`subdomain`), so a manual join/audit is still trivial.
3. **Java's role (ADR-0039/0022)** ✅ resolved. Removed: the customer-facing
   `java-api` REST API, its Cognito resource server/scopes, its NLB
   listeners, the `sap-java` connection type. Added (`shared/java_outbound.tf`):
   an SQS queue for Java's "batch complete" handoff to NestJS, and an IAM
   policy for Java to read Tenant SAP credentials
   (`tenant_settings.sap_credential_secret_ref`/`sap_oauth_token_secret_ref`)
   and publish to that queue — matching Java's actual role as a nightly
   *outbound* extraction worker, not an inbound API.

## Restored from merge-varunerp-network-infra (Sep 2026)

The Tenant integration hub stack described in §11 of
`INFRASTRUCTURE_REFERENCE.md` (Cognito, the 2 REST APIs, the shared Lambda
authorizer, the internal NLB, Java's outbound infra, the Postgres inventory
writer) had been deleted from `main`'s `terraform/` tree by an unrelated
commit (`c73584b`, "Replace terraform/ with docs/java-app-deployment-and-
gateway-network's exact tree") before the S3+CloudFront portal/support work
in this same `docs/infra/` tree began — leaving only the ADR/diagram
documentation for it, no actual Terraform. Restored from the
`merge-varunerp-network-infra` branch (author: Ravi Babu Koduri), with two
deliberate exclusions:

- **`terraform/modules/spa-hosting/` and `public_apps_cognito.tf`** — the
  branch's own design for react-external-app/react-support-app hosting,
  superseded by the S3+CloudFront+WAF design already live in
  `public_apps.tf`/`public_apps_domain.tf`/etc. Restoring both would create
  two competing Terraform designs for the same CloudFront distributions.
  `outputs.tf`'s `portal_app_hosting`/`support_app_hosting` outputs (which
  referenced that module) were dropped for the same reason —
  `spa_bucket_names`/`spa_distribution_ids`/`spa_distribution_domain_names`
  already cover the same information.
- **`terraform/customers/*`/`react_app_instance_id`** — already superseded
  on `main` (renamed to `terraform/tenants/*` upstream; `react_app_instance_id`
  removed entirely once that EC2 instance was terminated, parking lot #57).

Everything else (Cognito, `apis.tf`, `authorizer.tf`, `networking.tf`,
`domains_sap.tf`, `flow2.tf`, `inventory.tf`, `java_outbound.tf`, the
`lambda-authorizer`/`pg-inventory-writer`/`tenant-onboarding` modules,
`terraform/tenants/`) was restored as-is. `variables.tf` was merged (not
replaced) to keep the currently-live variables (`vpc_id`,
`app_server_subnet_ids`, etc.) alongside the newly-restored ones.
**Still not appliable** — several required variables have no value yet
(`private_subnet_ids`, `sap_proxy_instance_id`, `varunerpsolutions_com_zone_id`,
`aiarap_com_zone_id`, the `aiarap_db_*` variables) — confirmed via
`terraform validate` (passes) and `terraform plan` (fails cleanly asking for
exactly those, touches no real state). One naming note:
`aiarap_com_zone_id` assumes a Route53 zone for `aiarap.com` that doesn't
actually exist in this account (confirmed when `public_apps_domain.tf` was
built — DNS is externally managed at Hostinger) — reconcile before this
stack is actually adopted.

## Still open / not built

- **`var.tenant_sap_secret_arn_pattern`** (`shared/variables.tf`) is a
  guessed resource pattern for Tenant SAP credential secrets, not confirmed
  against the app's actual secret-creation code. Verify before relying on
  it.
- **Java's outbound network egress** (NAT Gateway, and per-Tenant VPN for
  any Tenant requiring private connectivity) isn't provisioned — only the
  credentials/queue access is. See `shared/README.md`'s "Explicitly out of
  scope" section.
- **Attaching `java_outbound_policy_arn` to java-app's actual instance
  role** — automatic only if `java_app_iam_role_name` is set.
- Whether `global.tenant_registry` is actually deployed yet in the real
  `aiarap` database — `pg-inventory-writer`'s migration doesn't depend on
  it (deliberately no FK), but worth confirming before assuming both
  projects' schemas coexist cleanly in practice, not just on paper.
