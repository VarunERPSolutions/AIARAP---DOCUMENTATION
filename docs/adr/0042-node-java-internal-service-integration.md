# Node → Java Internal Service Integration: REST over a Private Internal Load Balancer, Shared-Secret Bearer Auth

Resolves parking-lot [#43](0021-parking-lot.md) (synchronous internal API mechanism) and [#45](0021-parking-lot.md) (whether Java splits into two deployables). Companion to [ADR-0039](0039-sap-integration-technology-and-backend-stack.md) §4, which established that NestJS needs a synchronous internal API from Java but left the mechanism open.

## 0. Reconciling a stale Terraform exposure first

Before this design could be finalized, an inconsistency in `terraform/shared` needed resolving: `gateway_network.tf` (added 2026-09-10) wired `java_app` as a target behind a second internal NLB fronted by its own API-Gateway VPC Link — i.e., reachable from outside AIARAP's network, the same external surface `node`/`sap` get. That directly contradicts `main.tf`'s explicit comment (*"Java is deliberately NOT a backend here... it never receives inbound calls, so it has no Tenant-facing REST API, Cognito scope, or NLB listener"*) and `variables.tf`'s (*"No `java_environments` here — Java has no inbound Tenant-facing routing at all"*) — both of which are the newer files (`variables.tf` is the most recently modified file in the entire stack) and both of which are internally consistent with the tracked ADR-0039 decision. `gateway_network.tf`'s own header comments cite "ADR-0003/0004/0005," which — per the 2026-09-09 gap-analysis log (`docs/logs/2026-09-09-adr-gateway-decision-gap-analysis.md`) — are untracked draft ADRs at the AIARAP repo root, not the real tracked ADRs of those numbers (custom-fields-JSONB, schema-per-tenant, AWS-default-cloud).

**Conclusion**: `gateway_network.tf`'s Java/API-Gateway wiring was orphaned — written against a draft plan that was superseded before it was ever applied, and never cleaned up. No other file references its Java-specific resources (confirmed by grep). It has been removed outright, not merely left unreferenced — see the Terraform section of the implementing changeset for the exact resource list. Its `node_app` target group/listener were also removed as redundant: `node` already has a genuine external-facing target group in `networking.tf`, and Node is the *caller* in this design, never a target behind the Java-facing LB.

## 1. Decision

**Transport**: REST/HTTPS, same as everything else in this stack — no operational need (streaming, bidirectional push) has been shown that would justify gRPC.

**Network path**: `NestJS (node-app instance) → an internal Network Load Balancer → one of N Java instances`. Entirely inside the existing VPC/private subnets. **Never** through API Gateway/VPC Link — that surface stays reserved for genuine external Tenant/Salesforce/SAP traffic (ADR-0039). Node depends on the load balancer's own DNS name only; it has no instance-level knowledge of which or how many Java instances exist behind it.

**Multi-instance / horizontal capacity**: the LB's target groups are keyed by a list of instance IDs per environment (`var.java_environments[env].instance_ids`), not a single scalar — production runs ≥2 instances (spread across the two existing app-server subnets/AZs) for capacity and availability; dev/qa may run 1 today using the identical shape. Health checks against `/actuator/health` determine which instances receive traffic.

**Authentication**: a Secrets-Manager-backed shared-secret bearer token (`Authorization: Bearer <token>`), one secret per environment (`varunerp/internal/node-java/<env>`) — evaluated against the two existing internal/M2M patterns in this codebase:

| Pattern | Used for | Verdict here |
|---|---|---|
| Cognito client-credentials + OAuth scopes (`flow2.tf`, `cognito.tf`) | Genuinely external M2M callers (Tenant/VarunERP's own Salesforce reaching AIARAP over the public internet) needing an IdP-issued, scoped, rotatable token | **Rejected** — this hop never leaves the VPC; pulling in a public Cognito token endpoint for a private call adds an external dependency for no security benefit. |
| Secrets-Manager-backed static bearer token (ADR-0022, SAP Payment Webhook) | A caller AIARAP built and controls, over TLS, where the receiving side just needs to reject anyone without the shared value | **Adopted** — same reasoning applies even more cleanly here, since both ends are AIARAP's own code (ADR-0022's caller is Tenant-operated SAP). No new auth mechanism class introduced. |

**Java deployability**: stays **one** Spring Boot deployable (resolves #45 — no split into separate batch/sync-API services). The synchronous internal endpoint(s) and the nightly Spring Batch job run in the same JAR/container. Request handling is stateless (no session state, `SessionCreationPolicy.STATELESS`) — any instance behind the LB can serve any request, which is what makes horizontal scaling behind the LB meaningful at all.

**Same architecture across dev/QA/production**: identical Terraform shape (`java_environments` map of `{instance_ids, port}`) in every environment — only the instance IDs, counts, ports, and per-environment secret values differ. Dev/QA today share one EC2 instance via two Docker containers on different host ports (matching the existing `docker/README.md` dev/qa isolation model); production gets its own ≥2-instance entry once provisioned.

## 2. What this does not change

- Java remains outbound-only with respect to Tenant/SAP traffic (`java_outbound.tf`) — this ADR only adds a second, entirely internal capability (serving Node's synchronous calls), not a new external surface.
- The actual SAP BAPI-backed business logic behind any real synchronous endpoint (e.g. ADR-0029's checkout pricing simulation) is out of scope here — this ADR resolves the transport/network/auth mechanism only. A minimal `/internal/v1/ping` endpoint is implemented to prove the mechanism end-to-end (LB routing, health checks, multi-instance failover, auth rejection paths); real business endpoints reuse the same filter and network path.

## Open items

None remaining for #43/#45. Production's real instance IDs are still a placeholder in Terraform (`java_environments.prd`) pending that box(es) being provisioned — same open state as `node_environments.prd` (parking-lot #34).
