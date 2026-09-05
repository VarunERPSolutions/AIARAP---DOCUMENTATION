# AR Aging Trend Snapshots

A new BI-style pre-computed reporting layer answers "is the AR team actually collecting past-due balances, or just watching new invoices flow through Current" over a flexible period (week-over-week, month-over-month, or any custom range) — without computing that comparison at runtime on every dashboard view.

## Why runtime computation doesn't work here

The specific question asked — collection progress vs. new-invoice inflow — can't be answered from aggregate bucket totals alone. A bucket's total dropping between two points in time is ambiguous: it could mean genuine collection, or the same uncollected invoices simply aging into a worse bucket while new invoices refill the lower one. Disambiguating requires knowing, **per Invoice**, which bucket it sat in at each snapshot — that's inherently a stored fact table, not something cheap to derive live, and definitely not something to recompute per dashboard view.

## Three tables

- **`ar_aging_snapshot_run`** — one row per batch execution. Carries two distinct timestamps deliberately: `sap_extract_timestamp` (when the underlying Invoice/Payment data was last pulled from SAP) and `batch_run_at` (when this batch actually processed it into a snapshot) — a user needs both to judge data freshness, since a manual refresh can re-run against already-extracted SAP data without a new extraction. `triggered_by`/`requested_by` support both the scheduled cadence and an on-demand manual refresh.
- **`ar_aging_snapshot_invoice`** — the real fact table, one row per open Invoice per run. Joining two runs on `invoice_id` classifies what happened to each Invoice (full categories below) — collected via cash, credit memo, or write-off; aged into a worse bucket untouched; newly appeared; or reallocated to a residual Invoice. This is what an aggregate-only table could never disambiguate.
- **`ar_aging_snapshot_bucket`** — pre-aggregated rollup from the detail table, for fast headline dashboard reads without summing `ar_aging_snapshot_invoice` on every view.

Grain on both fact tables matches [ADR-0023](0023-ar-reconciliation-batch.md)'s AR Reconciliation batch: Payer + Company Code + Currency, since amounts in different currencies can't be combined.

## Refresh

Same job supports both a scheduled cadence (proposed weekly, matching the "week-over-week" framing) and an on-demand manual trigger (`triggered_by = 'manual_refresh'`, `requested_by` set) — a user-initiated refresh doesn't require a new SAP extraction if the existing one is still current; it re-runs the aging computation against whatever `invoice`/`payment` data already exists locally.

## Movement classification (resolved)

Comparing an Invoice's row across two `ar_aging_snapshot_invoice` runs (e.g. the $50K → $30K example that prompted this) classifies into one of:

- **`incoming_cash`**, **`credit_issued`**, **`bad_debt_writeoff`** — the Invoice's open balance shrank or closed, attributed by summing its `payment` rows (already carrying `settlement_category`, see the "Open amount reconciliation" section in `0001-phase-1-table-structures.md`) dated within the period between the two snapshots. These three map 1:1 onto `payment.settlement_category`'s existing values — no new column or table needed, just reading what's already there.
- **`aged`** — same Invoice, still open, now in a worse bucket, with no `payment` row in the period. This is the "not actually collecting, just watching it get older" signal the original ask was about.
- **`new`** — the Invoice wasn't present in the earlier run at all.
- **`reallocated`** — the Invoice closed via a `payment` row with `settlement_category = 'reallocated'` (a residual payment, per `0001-phase-1-table-structures.md`'s "Open amount reconciliation"). Not explicitly asked for in the original framing (cash / credit / write-off / aged), but needs its own bucket rather than being miscounted as `incoming_cash` or dropped silently — the balance didn't leave the books, it moved to a new Invoice row (which will itself show as `new` in the same period, so double-counting is a real risk to guard against in the query, not just a labeling nicety).

$50K → $30K in one bucket, for example, decomposes as: (sum of `incoming_cash` + `credit_issued` + `bad_debt_writeoff` payments against invoices in that bucket) + (amount that `aged` out to a worse bucket, netted against amount that aged **in** from a better one) + (`reallocated` amount) + (`new` invoices entering the bucket) = the $20K delta, fully accounted for.

## Pending Down Payments are visible, but never blended into a bucket (resolved, parking lot item 39)

A Payer checking their AIARAP balance should see the true full picture — open Invoices *and* any pending Sales Order Down Payment (`sales_order_payment`, ADR-0029) not yet applied — not just the aging buckets. `ar_aging_snapshot_down_payment` (new) carries a per-run summary (`pending_amount`/`order_count`), same Payer/Company Code/currency grain as `ar_aging_snapshot_bucket`, so the dashboard can show it as a clearly separate line.

Deliberately **not** folded into any bucket, including "Current" (`bucket_id IS NULL`): a Down Payment isn't an aged receivable at all — it's a credit already collected, awaiting application to a future Invoice. Showing it inside a bucket would misrepresent already-collected money as something still owed. Same reasoning AR Reconciliation (ADR-0023) applies to its own equivalent addition.

## Open items

- Exact scheduled cadence (weekly proposed, not committed) and how far back snapshot history is retained before any archival/pruning.
- The precise SQL for the classification above isn't written out here — this ADR establishes the categories and the data model that makes them computable, not the query itself.
