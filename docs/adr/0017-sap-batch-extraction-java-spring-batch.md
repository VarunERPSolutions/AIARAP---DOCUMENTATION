# SAP Batch Extraction: Polyglot Java/Spring Batch Service for Nightly Bulk Loads

Nightly bulk extraction of data from Tenants' SAP systems (large periodic pulls of Invoices/Bills/RFQs/POs, per Tenant per SAP system) is handled by a dedicated **Java + Spring Batch** service, separate from the Node/NestJS backend — a deliberate, narrowly-scoped amendment to [ADR-0009](0009-backend-nodejs-typescript.md)'s single-stack backend, not a reopening of it.

## Why a second stack, scoped this narrowly

Spring Batch provides chunked/checkpointed, restartable job processing — mid-run failure recovery, per-row skip/retry policies, partitioned steps for parallelism — as a mature, off-the-shelf framework. Node has no equivalent; the same guarantees would have to be hand-built from a queue library plus a custom checkpoint/watermark table. With nightly-bulk volumes for some Tenants expected to be large enough that this matters, that's a genuine structural advantage, unlike JCo (ADR-0009's rejected alternative advantage, moot since SAP is reached via OData/REST only).

Everything ADR-0009 already established still holds for the rest of the backend — shared TS types with the React frontend, one hiring pool, full ecosystem support for Stripe/Cognito/Textract — so the split is scoped to exactly this one workload rather than migrating the backend wholesale.

## What stays in NestJS

**Frequent/incremental syncs** (near-real-time delta pulls — smaller payloads, run often) stay in Node: comfortably within its capabilities via a scheduled job, a watermark/cursor per Tenant/entity, and direct upsert into the domain tables. There's no structural reason to split these out too.

**Promotion of staged data into domain records** also stays in NestJS (see below) — business logic stays single-sourced in one language regardless of which service extracted the raw data.

## Write path: staging tables, not final domain tables

The Java service writes directly to Postgres for throughput, but only into per-Tenant **staging/landing tables** — never straight into final domain tables (Bill, Invoice, RFQ, PO). A separate NestJS-owned promotion step applies custom-fields JSONB mapping ([ADR-0003](0003-custom-fields-via-jsonb.md)), Owner defaulting, validation, and audit-trail writes when moving staged rows into real domain tables. This keeps domain rules in one place instead of duplicating (and drifting) them across Java and TypeScript.

## Handoff: SQS event, not polling

On completing a nightly run, the Java service publishes a "batch complete" event (per Tenant/entity/run) to an SQS queue. NestJS consumes it to trigger promotion immediately, rather than polling a control table on an interval.
