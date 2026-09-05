# SAP Batch Extraction: Polyglot Java/Spring Batch Service for Nightly Bulk Loads

Nightly bulk extraction of data from Tenants' SAP systems (large periodic pulls of Payers/Customers/Invoices/Bills/RFQs/POs/Products, per Tenant per SAP system) is handled by a dedicated **Java + Spring Batch** service, separate from the Node/NestJS backend — originally a deliberate, narrowly-scoped amendment to [ADR-0009](0009-backend-nodejs-typescript.md)'s single-stack backend, not a reopening of it. **This scope has since broadened — see the ADR-0031 update below.**

**Update (Payer/Customer Extraction, `0002-scheduled-jobs.md`)**: `payer`/`payer_sales_area`/`payer_company_code`/`payer_hierarchy` (SAP KNA1/KNVV/KNB1/KNVH or Salesforce-equivalent, dual-sourced like `payer` itself) also added to this batch's scope — a genuine gap this doc had until now, more foundational than Product since almost every other entity here FK's into Payer. Payer/Customer promotes **first**, before every other entity in the same nightly run, since Invoice/Sales Order/payment-table composite FKs into `payer_company_code`/`payer_sales_area` depend on it existing already.

**Update (Product Extraction, `0002-scheduled-jobs.md`)**: Product master data (SAP MARA/MAKT/MVKE/MARM — `product`/`product_sales_org`/`product_uom`) was added to this same batch's scope rather than a new dedicated job — a Tenant's catalog can run to thousands of SKUs, the same bulk-volume/restart-safety justification already covering Invoices/Bills/RFQs/POs. `product_sales_org.list_price`/`product_payer_price` (pricing) and `product_image` (images) are explicitly NOT part of this — see the List Price Extraction job and ADR-0029's Product Catalog design respectively.

## Why a second stack, scoped this narrowly (original reasoning)

Spring Batch provides chunked/checkpointed, restartable job processing — mid-run failure recovery, per-row skip/retry policies, partitioned steps for parallelism — as a mature, off-the-shelf framework. Node has no equivalent; the same guarantees would have to be hand-built from a queue library plus a custom checkpoint/watermark table. With nightly-bulk volumes for some Tenants expected to be large enough that this matters, that's a genuine structural advantage — originally considered separate from JCo (ADR-0009's rejected alternative advantage, at the time thought moot since SAP was reached via OData/REST only; **no longer moot, see ADR-0031**).

Everything ADR-0009 already established still holds for the rest of the backend — shared TS types with the React frontend, one hiring pool, full ecosystem support for Stripe/Cognito/Textract — so the split is scoped to exactly this one workload rather than migrating the backend wholesale.

## What stays in NestJS

**Frequent/incremental syncs** (near-real-time delta pulls — smaller payloads, run often) stay in Node: comfortably within its capabilities via a scheduled job, a watermark/cursor per Tenant/entity, and direct upsert into the domain tables. There's no structural reason to split these out too.

**Promotion of staged data into domain records** also stays in NestJS (see below) — business logic stays single-sourced in one language regardless of which service extracted the raw data.

## Write path: staging tables, not final domain tables

The Java service writes directly to Postgres for throughput, but only into per-Tenant **staging/landing tables** — never straight into final domain tables (Bill, Invoice, RFQ, PO). A separate NestJS-owned promotion step applies custom-fields JSONB mapping ([ADR-0003](0003-custom-fields-via-jsonb.md)), Owner defaulting, validation, and audit-trail writes when moving staged rows into real domain tables. This keeps domain rules in one place instead of duplicating (and drifting) them across Java and TypeScript.

## Handoff: SQS event, not polling

On completing a nightly run, the Java service publishes a "batch complete" event (per Tenant/entity/run) to an SQS queue. NestJS consumes it to trigger promotion immediately, rather than polling a control table on an interval.

## Update ([ADR-0031](0031-sap-integration-bapi-first-java-owns-all-sap-calls.md)): scope broadened to all SAP integration, not just nightly batch

AIARAP now prefers BAPI first (OData second) for every SAP call platform-wide, and JCo (the RFC/BAPI connector) has no first-party Node.js equivalent. This service is therefore no longer scoped to nightly bulk extraction alone — it becomes **the sole SAP integration layer**, also handling real-time/synchronous SAP calls on NestJS's behalf (e.g. ADR-0029's checkout-time pricing simulation and Sales Order creation) via a new synchronous internal API, alongside its existing Spring Batch jobs. Business logic, orchestration, and retry/failure-escalation stay owned by NestJS — this service remains a thin integration/execution layer, not a place where domain rules live, consistent with the "business logic stays single-sourced in NestJS" principle above. Whether this warrants splitting into two deployables (a batch runner + a synchronous API service) is an open item in ADR-0031.
