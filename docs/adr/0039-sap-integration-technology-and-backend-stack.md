# SAP Integration Technology: Java Owns All SAP Calls (BAPI First), NestJS Stays the API/Business-Logic Layer

The single, living record for which stack talks to SAP and how. **Consolidates and supersedes three ADRs**, each kept in place as a short historical stub pointing here: [0009](0009-backend-nodejs-typescript.md) (original backend stack decision, including its now-corrected "SAP is OData/REST only" premise), [0017](0017-sap-batch-extraction-java-spring-batch.md) (Java/Spring Batch carved out for nightly extraction), [0031](0031-sap-integration-bapi-first-java-owns-all-sap-calls.md) (BAPI-first, Java's scope broadened to real-time calls too). Each amended the one before it via an inline "Update (ADR-00XX)" note — that chain is merged here into one current-state narrative.

## 1. Backend: Node.js + TypeScript (NestJS) — API/business-logic layer

NestJS remains the stack for the API backend and all request-driven/incremental work — this hasn't changed. It shares a language with the React/TypeScript frontend ([ADR-0008](0008-frontend-react-spa.md)), enabling shared DTOs/validation types and a single hiring pool, and has full, mature support for everything else the backend talks to: Stripe, AWS Textract, AWS Cognito, and Salesforce OData/REST. **What's no longer true**: NestJS does not call SAP directly, for anything — see Decision 2 below. That's the one premise of the original decision that changed; everything else about the choice of stack stands.

## 2. SAP integration layer: Java, BAPI first/OData second, owns every SAP call

BAPIs (via RFC) have existed since R/3 and cover almost every business process across both ECC and S/4HANA alike, with no additional per-Tenant Gateway/SICF activation typically required beyond connectivity that's often already in place. OData/Gateway services are newer, may be unconfigured or unavailable on older ECC Tenant landscapes, and require their own per-Tenant service exposure/security configuration. **BAPI is the default, OData the fallback** — used per-Tenant/per-call where a released BAPI doesn't cover the need, or where a Tenant's network/security policy blocks classic RFC and only permits HTTPS.

BAPI/RFC connectivity requires SAP's **JCo** connector, officially supported only for Java and .NET — no first-party Node.js equivalent exists (only unofficial community bindings, e.g. `node-rfc`, carrying real unsupported-native-binary risk). Since BAPI is now the default for **every** SAP call, including the live/synchronous ones that used to sit in NestJS's own request path, **all SAP integration — real-time and batch — belongs to the Java service**: NestJS never talks to SAP directly, for anything.

This arose out of researching SAP Digital Access licensing ([ADR-0030](0030-sap-digital-access-tenant-responsibility.md)) — that research established BAPI and OData are **licensing-equivalent** (parking lot #41), so this is driven entirely by technical reasoning, not licensing.

## 3. Nightly batch extraction (Spring Batch)

Large periodic pulls from Tenants' SAP systems — Payers/Customers, Invoices, Bills, RFQs, POs, Products (dual-sourced from SAP or Salesforce where applicable) — run through **Java + Spring Batch**, not NestJS. Spring Batch provides chunked/checkpointed, restartable job processing (mid-run failure recovery, per-row skip/retry policies, partitioned steps) as a mature, off-the-shelf framework; Node has no equivalent, and the same guarantees would otherwise have to be hand-built from a queue library plus a custom checkpoint/watermark table. Worth it at the volumes some Tenants' nightly bulk loads reach.

- **Write path**: Java writes only into per-Tenant **staging/landing tables**, never straight into final domain tables (Bill, Invoice, RFQ, PO, Payer, Product). A separate NestJS-owned promotion step applies custom-fields JSONB mapping ([ADR-0003](0003-custom-fields-via-jsonb.md)), Owner defaulting, validation, and audit-trail writes when moving staged rows into real domain tables — business logic stays single-sourced in one language regardless of which service extracted the raw data.
- **Handoff**: on completing a nightly run, Java publishes a "batch complete" event (per Tenant/entity/run) to SQS; NestJS consumes it to trigger promotion immediately, rather than polling a control table.
- **Scope**: Payer/Customer promotes **first**, before every other entity in the same run, since Invoice/Sales Order/payment-table composite FKs depend on it existing already. Product master data is included on the same bulk-volume/restart-safety justification as Invoices/Bills/RFQs/POs (pricing and images are explicitly separate — see the List Price Extraction job and ADR-0029's Product Catalog design).
- **What stays in NestJS regardless**: frequent/incremental delta syncs (smaller payloads, run often — a watermark/cursor per Tenant/entity, direct upsert) have no structural reason to move to Spring Batch; nor does anything money-adjacent-but-lightweight, except where restart-safety specifically demands it (e.g. the Automatic Card Payment batch, which is Spring Batch-tiered purely because a mid-run crash must never double-charge an Invoice — see ADR-0019).

## 4. Real-time SAP calls (synchronous internal API)

For a live need — e.g. [ADR-0029](0029-sales-order-checkout-fi-down-payment.md)'s checkout-time pricing simulation and real-time Sales Order creation — NestJS calls a **new synchronous internal API** exposed by the Java service, which executes the actual BAPI (or OData fallback) call against SAP and returns the result inline. This is a real scope addition to that service: the Java service, previously a pure Spring Batch job runner, needs a synchronous request-handling capability alongside its existing batch jobs (e.g. a Spring Boot MVC/WebFlux layer).

**Java stays a thin execution layer — it gains no business logic.** Orchestration, retry/backoff, and failure escalation (e.g. ADR-0029's "retry, then notify the AR Clerk" behavior when SAP order creation fails after a successful charge) stay owned by NestJS, same principle as the batch side: business logic stays single-sourced in one language regardless of which service touches SAP.

**Tradeoff accepted**: one additional internal network hop (NestJS → Java → SAP) versus a hypothetical direct NestJS-to-SAP call, in exchange for JCo's official support (vs. an unofficial Node RFC binding) and BAPI's broader coverage across Tenants' varying ECC/S4HANA landscapes.

## Also resolved

**Latency budget/SLA for the checkout flow's call chain**: no number set — deliberately deferred to implementation time. Measure the real Java↔SAP/NestJS↔Java call chain once built, then discuss the acceptable checkout-UX threshold with the Tenant, rather than pinning a speculative SLA now (parking lot #44).

## Open items

See [parking lot](0021-parking-lot.md) #43 (exact synchronous API mechanism between NestJS and Java — REST vs. gRPC, internal auth scheme), #45 (whether the Java service splits into two deployables — batch runner + synchronous API service — or stays one), #37/#38 (per-integration-point BAPI-vs-OData service names — pricing simulation and order creation already resolved to specific BAPIs, OData/S4HANA fallback still unverified for both).
