# AR Reconciliation Batch

A new job compares each Tenant's SAP-side open AR balance against AIARAP's own computed `invoice.open_amount`, identifies discrepancies at the Payer + Company Code ("account") level, and persists enough detail to drill down to the specific documents causing each one.

## Why three tables, not one

- **`ar_reconciliation_run`** — one row per run. Deliberately carries **no single total-variance number** — SAP AR balances span multiple currencies (a Payer can have foreign-currency Invoices), and summing across currencies would be a meaningless number. Just run metadata and counts (`accounts_checked`, `accounts_with_variance`).
- **`ar_reconciliation_account`** — the account-level rollup requested (Payer + Company Code), with `currency` as part of the grain rather than a column bolted onto a currency-agnostic total: an account with both USD and EUR open items gets two rows. **Every account gets a row on every run, including zero-variance ones** — "has this account been clean for the last 30 runs" is then a direct query against explicit rows, not an inference from an absence of rows.
- **`ar_reconciliation_discrepancy`** — the document-level drill-down, one row per specific Invoice (or per SAP open item AIARAP has no matching Invoice for) contributing to a given account's variance.

## Discrepancy types

- `amount_mismatch` — both sides have the document, but the amounts differ.
- `missing_in_aiarap` — SAP shows an open item AIARAP has no matching Invoice row for at all (a missed or delayed extraction). `invoice_id` is NULL; `sap_document_reference` carries SAP's own document number/year instead.
- `missing_in_sap` — AIARAP shows an Invoice as open that SAP's current open-item list doesn't include (e.g. cleared in SAP but not yet synced, or a sync bug).

## Tier and cadence

NestJS, not Spring Batch — unlike the Automatic Card Payment batch ([ADR-0019](0019-automatic-card-payment-batch.md)), this job moves no money and has no restart-safety stakes; it's a comparison/reporting job over a bounded number of Payer/Company Code combinations per Tenant, the same category as Currency Exchange Rate Extraction and Invoice Type Extraction. Proposed cadence: daily (not firmly committed — could reasonably be weekly depending on how often Tenants actually want to look at this).

## SAP-side data isn't only from batch extraction

The "SAP-side open AR balance" this job compares against doesn't have to come solely from a periodic OData pull. Per [ADR-0022](0022-sap-payment-webhook.md)/[ADR-0027](0027-salesforce-appexchange-integration.md)'s design principle, the SAP Payment Webhook and Salesforce AppExchange package are deliberately built to carry richer payloads than the bare minimum for critical events — including the account's current open balance at the moment of a push.

## Reconciling real-time push data with the scheduled batch (resolved, parking lot item 27)

There isn't actually a "which one wins" merge problem here, once the freshness relationship is worked through: a **scheduled run always wins on freshness by construction** — it performs a live SAP extraction at the moment it executes, so an earlier webhook push can never be fresher than a pull happening right now. Blending the two into one number, or picking whichever is "most recent," would be solving a problem that doesn't actually exist.

What real-time push data is actually good for is **narrowing the detection window between scheduled runs**, not improving the scheduled run's own number. `ar_reconciliation_run.trigger_type` (new — `'scheduled'` | `'webhook_triggered'`, see `0001-phase-1-table-structures.md`) distinguishes the two: a webhook carrying balance data triggers its own run scoped to just the one account it concerns (`accounts_checked = 1`), comparing the pushed balance directly against `invoice.open_amount` and writing to the same `ar_reconciliation_account`/`ar_reconciliation_discrepancy` tables a scheduled run would. This fires within minutes of a payment posting rather than waiting up to a day for the next scheduled sweep — closing the detection window without needing to override, be overridden by, or reconcile against the scheduled run's own results. Both run types coexist as independent rows, full history preserved, same "every account every run, nothing deleted" convention already established for scheduled runs.

## Open items

- Exact SAP extraction query for "current open AR balance per document" (BSID-equivalent) — not designed here, follows the same OData extraction pattern as other SAP-sourced data in this doc.
- Whether `missing_in_sap` discrepancies should auto-trigger anything (e.g. re-running the Invoice sync for that specific Invoice) versus staying purely informational for a human to investigate — not decided.
- Whether a `webhook_triggered` run finding a discrepancy should fire its own immediate Notification (reusing the Notification Channel, ADR-0026) or simply wait to be surfaced on the next scheduled dashboard view — not decided.
