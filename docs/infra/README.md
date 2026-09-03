# Infrastructure reference

Merged in from the standalone `VarunERP_Network` project (Tailscale employee
access + the customer integration hub). Kept as-is from that project for
now — **not yet reconciled against this project's own ADRs/schema docs**;
see the merge notes below for the conflicts found and what's still open.

- `INFRASTRUCTURE_REFERENCE.md` — AWS + Tailscale employee access, plus a
  summary of the customer integration hub (§11) pointing at `terraform/`
  and `docker/` at the repo root.
- `architecture-diagram.html` — the visual: Figure 1 (Tailscale/employee
  access), Figure 2 (customer integration hub, with a full request
  walkthrough for three example calls).

## Known conflicts with this project's existing ADRs/schema — not yet resolved in code

1. **Terminology**: the infra project uses "customer"/`customer_id`
   throughout (Cognito clients, API keys, the inventory schema, Terraform
   variable names). This project's own glossary (`CONTEXT.md`) explicitly
   says to avoid "Customer" in favor of **Tenant**, and already has a
   `global.tenant_registry.subdomain` field that's the same concept as the
   infra project's `custXX.aiarap.com` per-customer subdomain. Needs a
   rename pass through `terraform/modules/customer-onboarding` and
   `terraform/shared` (module name, variable names, Cognito client/scope
   naming, secret paths).
2. **Schema-per-tenant ([ADR-0004](../adr/0004-schema-per-tenant-isolation.md))**:
   `pg-inventory-writer` creates one shared `integration_inventory` schema
   with a `customer_id`/tenant-discriminator column — the exact
   single-schema-with-discriminator pattern ADR-0004 explicitly considered
   and reaffirmed rejecting. Since this data (Cognito client IDs, API key
   IDs, secret ARNs — governance metadata, not Tenant business data) is
   conceptually cross-tenant and AIARAP-internal, it likely belongs inside
   the existing **`global` schema** (alongside `global.tenant_registry`,
   `global.aiarap_staff`) rather than its own competing schema — not yet
   changed in the Terraform.
3. **Java's actual role — a real architecture conflict, not a naming one**:
   the infra project built a customer-facing `java-api` REST API/Cognito
   resource server, on the assumption that a Tenant's SAP system calls
   *into* Java directly. Per [ADR-0017](../adr/0017-sap-batch-extraction-java-spring-batch.md),
   Java/Spring Batch is scoped **exclusively to nightly outbound bulk
   extraction** — AIARAP's Java service calls *out* to each Tenant's SAP
   system on a schedule, writing to staging tables; it never receives
   inbound calls from a Tenant. The one real inbound-from-SAP path
   ([ADR-0022](../adr/0022-sap-payment-webhook.md), the SAP Payment Webhook)
   is request-driven and belongs on the NestJS backend (Node), per
   [ADR-0009](../adr/0009-backend-nodejs-typescript.md)'s "frequent/
   incremental work stays in Node." **The customer-facing `java-api` REST
   API, its Cognito scopes, and the `sap-java` connection type in
   `customer-onboarding`'s default connection list are built on the wrong
   direction and need to be reworked — not just renamed** — into proper
   *outbound* connectivity (Java/AIARAP reaching each Tenant's SAP system),
   likely reusing the same per-Tenant Secrets Manager credential pattern
   already used elsewhere in `tenant_settings`.

Not fixed in this merge — flagging clearly rather than guessing at a fix
this consequential without confirming the resolution first.
