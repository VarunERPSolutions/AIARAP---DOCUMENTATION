# SAP Integration Technology: BAPI First (OData Second), Java Owns All SAP Integration — Real-Time and Batch

This ADR **reopens and supersedes** a specific premise in [ADR-0009](0009-backend-nodejs-typescript.md) and broadens [ADR-0017](0017-sap-batch-extraction-java-spring-batch.md)'s scope. It arose out of researching SAP Digital Access licensing (ADR-0030) — that research established BAPI and OData are **licensing-equivalent** (parking lot item 41), so this decision is driven entirely by technical reasoning, not licensing.

## Decision 1: BAPI first, OData second, for every SAP call platform-wide

BAPIs (via RFC) have existed since R/3 and cover almost every business process across both ECC and S/4HANA alike, with no additional per-Tenant Gateway/SICF activation typically required beyond connectivity that's often already in place. OData/Gateway services are newer, may be unconfigured or simply unavailable on older ECC Tenant landscapes (the same "some Tenants' SAP systems are older/limited" concern already flagged in ADR-0022), and require their own per-Tenant service exposure and security configuration. BAPI is the default; OData is the fallback, used per-Tenant/per-call where a released BAPI doesn't cover the need, or where a specific Tenant's network/security policy blocks classic RFC and only permits HTTPS.

## Decision 2: Java becomes the sole SAP integration layer — real-time calls included, not just batch

BAPI/RFC connectivity requires SAP's **JCo** connector, officially supported only for Java and .NET — there is no first-party Node.js equivalent (only unofficial community bindings, e.g. `node-rfc`, which carry real unsupported-native-binary risk). Since Decision 1 makes BAPI the default for **every** SAP call, including the live/synchronous ones that live in NestJS's request path today (e.g. [ADR-0029](0029-sales-order-checkout-fi-down-payment.md)'s checkout-time pricing simulation and real-time Sales Order creation), NestJS can no longer be the stack that talks to SAP directly for those either.

**All SAP integration — real-time and batch — moves to the Java service** established in ADR-0017, which already owns JCo/RFC connectivity for nightly bulk extraction. This is a genuine reopening of two specific statements, not a narrow addition:

- ADR-0009's "Tenants' SAP systems are reached exclusively via OData/REST, not RFC/BAPI" is **no longer true** — corrected in that ADR (see below).
- ADR-0017's framing of the Java carve-out as "a narrow, deliberate exception, not a reopening of this decision" is **no longer accurate** — this ADR **is** the reopening, explicitly scoped to "which stack owns SAP integration." Everything else ADR-0009 established (shared TypeScript types with the React frontend, one hiring pool, full ecosystem support for Stripe/Cognito/Textract) still holds for the rest of the backend — NestJS remains the API/business-logic layer for everything that isn't a direct SAP call.

## Mechanics: Java as a thin execution layer, NestJS keeps the business logic

NestJS no longer calls SAP directly for anything, real-time or batch. For a live need like ADR-0029's checkout flow, NestJS calls a **new synchronous internal API** exposed by the Java service, which executes the actual BAPI (or OData fallback) call against SAP and returns the result. Java becomes a thin integration/execution layer — it does not gain new business logic. Orchestration, retry/backoff, and failure escalation (e.g. ADR-0029's "retry, then notify the AR Clerk" behavior when SAP order creation fails after a successful charge) **stay owned by NestJS**, consistent with ADR-0017's existing principle that business logic stays single-sourced in one language regardless of which service touches SAP.

This means the Java service, currently a pure Spring Batch job runner, needs a **synchronous request-handling capability** alongside its existing batch jobs (e.g. a Spring Boot MVC/WebFlux layer) — a real scope addition to that service, not something it already has.

## Tradeoff acknowledged

This adds one internal network hop (NestJS → Java → SAP) to latency-sensitive, interactive flows like checkout, versus a hypothetical direct NestJS-to-SAP call. Accepted in exchange for using SAP's officially-supported JCo connector rather than an unofficial Node RFC binding, and for BAPI's broader coverage across Tenants' varying ECC/S4HANA landscapes.

## Also resolved

**Latency budget/SLA for the checkout flow's now-longer call chain**: no number set — deliberately deferred to implementation time. Measure the real Java↔SAP/NestJS↔Java call chain once built, then discuss the acceptable checkout-UX threshold with the Tenant, rather than pinning a speculative SLA now. See parking lot item 44.

## Open items

- Exact synchronous API mechanism between NestJS and the Java service (REST vs. gRPC, internal auth scheme) — not yet designed.
- Whether the Java service should split into two deployables (a batch runner + a separate synchronous API service) or stay one — not yet decided.
- Per-integration-point BAPI-vs-OData choice remains an implementation-time task (same treatment as parking lot items 37/38 — exact BAPI/OData service names for pricing simulation and order creation, now additionally routed through Java rather than called directly from NestJS).
