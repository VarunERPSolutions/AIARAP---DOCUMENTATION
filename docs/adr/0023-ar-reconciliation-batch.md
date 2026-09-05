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

## Webhook-triggered discrepancies notify immediately; scheduled ones stay dashboard-only (resolved, parking lot item 28)

**Exactly when a `webhook_triggered` run fires**: it's the inbound event handler for the SAP Payment Webhook (ADR-0022) or the Salesforce AppExchange package (ADR-0027) that invokes it — inline, as part of processing that event — not a separate listener or a delay of any kind. Concretely: when AIARAP receives one of those webhook events and its payload happens to include the account's current open balance (per the "richer payload for critical data" design principle both ADRs already establish — a payment-posting push, for instance, commonly carries the account's balance *at the moment of posting* alongside the payment itself), that same event-handling code path immediately kicks off a new `ar_reconciliation_run` row (`trigger_type = 'webhook_triggered'`, `accounts_checked = 1`) scoped to just that one Payer/Company Code/currency, comparing the pushed balance directly against `invoice.open_amount`. There's no polling, no queue, no separate cron — the webhook event itself *is* the trigger, and the whole run (single account, no bulk extraction needed) completes fast enough to happen synchronously within that same request. If the SAP or Salesforce event's payload does *not* happen to carry a balance figure, no webhook-triggered run fires for it at all — this path is opportunistic on the richer-payload principle actually applying to a given event, not guaranteed on every single inbound webhook.

A `webhook_triggered` run finding a discrepancy fires an immediate Notification (reusing the Notification Channel, ADR-0026) to the affected account's AR Clerk (`payer_company_code.accounting_clerk_user_id`) — same recipient-resolution pattern used everywhere else in this doc. Two reasons this is scoped to `webhook_triggered` runs only, not extended to scheduled runs too:

1. **It's the reason the fast path exists.** The whole point of the webhook-triggered run is narrowing the detection window between scheduled sweeps — if a discrepancy it finds just waits for the next scheduled dashboard view, the speed advantage is real for detection but wasted for action.
2. **It's a genuinely different situation, not just a faster version of the same finding.** A webhook-triggered run is single-account and fires immediately after a real-time balance push — a fresh, event-tied discrepancy, materially more likely to be actionable *right now* than one surfaced by a routine periodic sweep. Notifying on every scheduled discrepancy too would be noisy for a much weaker signal.

**Caveat, not a blocker**: `ar_reconciliation_discrepancy` has no dedup/`resolved_at` tracking (every run writes independent rows, per the "every account every run" convention above) — two webhook-triggered runs close together on the same still-broken account could notify twice before it's fixed. Accepted as a minor tradeoff for Phase 1 rather than designed around.

## Pending Down Payments are visible, but never summed into variance (resolved, parking lot item 39)

A FI Down Payment (`sales_order_payment`, ADR-0029) posts against a different reconciliation account (Advances from Customers, not Trade Receivables) and isn't a normal open-AR item until cleared. `ar_reconciliation_account.pending_down_payment_amount` (new) surfaces it as **additive visibility only** — never summed into `variance_amount`, which stays purely about matching SAP Trade Receivables against `invoice.open_amount`. A Payer checking their AIARAP balance should see the true full picture (open Invoices *and* any pending Down Payment) as two clearly separate numbers, same "don't sum what genuinely can't be summed" discipline already applied to cross-currency amounts in this domain. Same reasoning and equivalent addition on the AR Aging side — see ADR-0024.

## Open items

- Exact SAP extraction query for "current open AR balance per document" (BSID-equivalent) — not designed here, follows the same OData extraction pattern as other SAP-sourced data in this doc.
- Whether `missing_in_sap` discrepancies should auto-trigger anything (e.g. re-running the Invoice sync for that specific Invoice) versus staying purely informational for a human to investigate — not decided.
