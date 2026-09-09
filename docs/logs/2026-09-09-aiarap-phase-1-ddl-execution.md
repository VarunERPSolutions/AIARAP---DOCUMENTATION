# 2026-09-09 — AIARAP Phase 1 DDL Execution

**Excel log row:** [AIARAP_Daily_Implementation_Log.xlsx](../../AIARAP_Daily_Implementation_Log.xlsx), row dated 2026-09-09, "AIARAP Phase 1 DDL execution"
**Status:** Done

## Goal

Turn the Phase 1 schema design (written narratively, domain-by-domain, across `docs/schema/0001-phase-1-table-structures.md`) into one executable PostgreSQL script, and run it against the project's Amazon RDS PostgreSQL instance.

## Process

1. **Located the DDL.** The AR/AP Phase 1 spec (`docs/spec/0001-ar-ap-phase-1.md`) describes the product; the actual `CREATE TABLE` statements live in `docs/schema/0001-phase-1-table-structures.md`, organized domain-by-domain (Tenancy & Identity → Security/Roles → Core AR/AP → Access/Onboarding → Batch/Integration), 2,728 lines total.

2. **First-pass extraction.** Pulled every ```sql fenced block out of that one file into a scratch file to get a quick sense of scope (80 `CREATE TABLE` statements found).

3. **Full documentation-wide review (on request).** Re-scanned the entire `AIARAP---DOCUMENTATION` folder — all 39 ADRs, `docs/schema`, `docs/spec`, `docs/plan`, `docs/infra`, `CONTEXT.md`, `terraform`, `docker` — via a background agent, to confirm no DDL existed outside the one schema doc and to catch any ADR-level supplementary SQL.
   - Confirmed: `docs/schema/0001-phase-1-table-structures.md` is the sole authoritative source (80 `CREATE TABLE`, 154 indexes).
   - `docs/adr/0029-...` (`company_code`) and `docs/adr/0038-...` (`payer_email_domain`, `app_user_contact`) contain earlier draft snippets of tables that were later folded into 0001 — diffed programmatically and found **byte-identical modulo comments**, i.e. not real conflicts.
   - `docs/schema/0002-scheduled-jobs.md` contains zero SQL fences.
   - No triggers, functions, roles, policies, or views are defined anywhere in the documentation.

4. **Dependency-safe ordering.** The source document has tables referencing others defined later in the file (explicitly flagged in its own comments as forward references, e.g. `payer_payment_card` → `company_code`, `card_payment` → `invoice`). Rather than hand-resolving each one, used a two-pass strategy:
   - Pass 1: all 80 tables created with FK clauses stripped.
   - Pass 2: all 182 FK constraints added via `ALTER TABLE ... ADD CONSTRAINT`.
   - This guarantees correct execution order regardless of the document's narrative ordering.

5. **Bootstrap objects added** (none of these change any documented table/column):
   - `CREATE EXTENSION IF NOT EXISTS citext;` (case-insensitive email columns, per the doc's own convention).
   - `uuidv7()` assumed native (Postgres 18+, per the doc's stated PK convention); a commented-out `CREATE EXTENSION pg_uuidv7;` fallback line included for older engine versions.
   - `CREATE SCHEMA global;` for AIARAP-internal cross-tenant tables.
   - `CREATE SCHEMA tenant_template;` as the one-schema-per-tenant placeholder — the doc specifies tenant tables are deployed identically per Tenant, so this schema is the template to clone per new Tenant.

6. **Preservation check.** Verified programmatically that all 1,008 typed columns across all 80 tables match the source document's names and types exactly — no renames, drops, or type changes were made anywhere.

7. **Deliverable:** [`docs/schema/aiarap_full_ddl.sql`](../schema/aiarap_full_ddl.sql) (1,791 lines) — one ordered, executable script.

8. **Execution.** User ran the script against the project's Amazon RDS PostgreSQL instance. All 80 tables and 182 foreign-key constraints created successfully, no errors reported.

9. **Logged.** Recorded as a row in `AIARAP_Daily_Implementation_Log.xlsx` (Daily Log sheet) — this file is that row's companion detail doc.

## Source documents used

- `docs/spec/0001-ar-ap-phase-1.md`
- `docs/schema/0001-phase-1-table-structures.md` (primary DDL source, read in full)
- `docs/schema/0002-scheduled-jobs.md` (checked, no DDL)
- `docs/adr/0029-sales-order-checkout-fi-down-payment.md` (cross-checked, no conflict)
- `docs/adr/0038-portal-support-app-public-exposure-domain-cognito-and-signup.md` (cross-checked, no conflict)
- All other ADRs in `docs/adr/` (scanned, no DDL found)

## Open items / notes for future sessions

- No conflicts, missing dependencies, or undocumented-but-referenced objects (triggers/functions/roles/policies) were found — nothing was invented to fill a gap.
- `tenant_template` schema needs to be cloned (all 80 tables + relevant FKs) into a real per-Tenant schema (e.g. `acme`) at actual Tenant onboarding time — the script only sets up the template, consistent with "uniform schema across all Tenants, no per-tenant drift" from the spec.
- If the RDS engine version is later found to be below Postgres 18, swap the native `uuidv7()` assumption for the commented-out `pg_uuidv7` extension path in `aiarap_full_ddl.sql`.
