# Stripe Payout Reconciliation

A new job extracts Stripe's daily payout details and verifies every AIARAP-originated transaction matches between `card_payment` and what Stripe actually settled — closing the loop between "Stripe told AIARAP the charge succeeded" (`card_payment`, [ADR-0019](0019-automatic-card-payment-batch.md)) and "Stripe actually paid it out to the Tenant's bank account."

## AIARAP-origin is inferred, not tagged

A Tenant's Stripe Connected Account (ADR-0020) isn't necessarily used only by AIARAP — it can carry charges from SAP-adjacent processes or other systems the Tenant already had. Stripe itself has no concept of "this charge came from AIARAP." So `stripe_payout_transaction.matched_card_payment_id` is populated purely by matching `stripe_charge_ref` against an existing `card_payment.provider_charge_ref` — a transaction with no match isn't an error, it's simply not AIARAP's to explain.

## Full payout visibility, not just AIARAP's slice

Since the entire payout lands in the Tenant's bank account, reconciliation surfaces the full composition — AIARAP-matched total and "other" total both shown, clearly distinguished — rather than staying silent about the portion AIARAP didn't originate. Discrepancy *checking* (below) applies only to the AIARAP-matched portion; AIARAP has no basis to judge whether an unmatched transaction is correct.

## Bucketing Stripe's raw transaction types

Stripe's `balance_transaction.type` enum is large and still growing — `charge`, `refund`, `payment`, `adjustment`, `application_fee`, `application_fee_refund`, `transfer`, `transfer_reversal`, `stripe_fee`, `network_cost`, `tax_fee`, `reserve_transaction`, `reserved_funds`, `payout`, `payout_cancel`, `payout_failure`, `topup`, `topup_reversal`, and more — too granular for a Tenant's finance team to reason about directly. `stripe_transaction_type_bucket` (new, see `0001-phase-1-table-structures.md`) maps each raw type down into one of a small, fixed set of buckets (`charge`, `refund`, `fee`, `reserve`, `payout`, `adjustment`, `transfer`, `other`), seeded with sensible defaults per Tenant and editable from there — same "seeded, then Tenant-editable" pattern as `notification_template`. The bucket *list* itself is fixed (a CHECK constraint), not Tenant-invented — the goal is simplification, not moving the same confusion up one level into inconsistent custom bucket names.

`stripe_payout_transaction.transaction_type` carries a real FK into this mapping table rather than staying unconstrained: if Stripe ships a new type AIARAP hasn't mapped yet, extraction fails loudly (a mapping row needs adding) instead of silently defaulting it into the wrong bucket. `bucket` itself is a denormalized snapshot taken at ingestion time, not a live join — editing the mapping later doesn't retroactively change how historical transactions are shown, matching the "store what was actually true at the time" convention already used for `notification.subject`/`body`.

## Foreign-currency Invoices: separating FX gain/loss from Stripe fees

For a foreign-currency Invoice, Stripe converts the charge into the Tenant's payout currency at its own exchange rate — a distinct economic event from its processing fee, and one a Tenant's finance team needs to see separately (FX gain/loss and card processing fees are accounted for completely differently). `stripe_payout_transaction.presentment_amount`/`presentment_currency`/`exchange_rate` (new, see `0001-phase-1-table-structures.md`) capture the original-currency side of the transaction alongside the existing settlement-side `gross_amount`/`fee_amount`/`net_amount`/`currency` — all three are NULL when no conversion occurred. Comparing Stripe's own `exchange_rate` against AIARAP's SAP-sourced `currency_exchange_rate` for the same currency pair/date is what isolates the FX variance from `fee_amount`, rather than the two being blended into a single unexplained gap between what was charged and what was paid out.

## Discrepancy types

Unlike AR Reconciliation (ADR-0023), there's no `missing_in_aiarap`-equivalent type here — an unmatched Stripe transaction is presumed non-AIARAP by default, not a gap to investigate. Only two types apply, both anchored to an AIARAP `card_payment` row (`card_payment_id` is always set):

- `amount_mismatch` — the transaction matched by `stripe_charge_ref`, but gross/fee/net amounts disagree between `card_payment` and `stripe_payout_transaction`.
- `missing_in_stripe_extract` — AIARAP has a succeeded/posted `card_payment` that hasn't appeared in any extracted payout yet. `stripe_payout_transaction_id` is NULL (nothing to point at). This needs a grace period before flagging (Stripe payouts settle with a delay) — flagging immediately would produce false positives for perfectly normal pending settlement, not real discrepancies.

### Timing: Stripe's UTC cutoff, not calendar-day alignment

Stripe's balance-transaction day boundary is **GMT/UTC midnight**, not the Tenant's local business day. A charge made late in the Tenant's local evening can fall on either side of that UTC cutoff depending on the Tenant's timezone offset — so a naive "was this `charged_at` day's charge included in that same day's payout" check produces false `missing_in_stripe_extract` flags purely from boundary misalignment, not real discrepancies. The matching logic therefore checks for a match within a **rolling window from `charged_at`** (all compared in UTC) rather than expecting alignment with one specific expected payout/business day. `missing_in_stripe_extract` only fires once that whole window has elapsed with no match.

**Window width (resolved): auto-derived per Tenant, not a single platform-wide constant.** A flat 5-business-day default would false-flag Tenants on a genuinely slower payout schedule (weekly, monthly, or a newer/higher-risk account with a longer delay) while potentially being looser than necessary for others. Rather than a manually-configured override — which would require a Tenant Admin to know and correctly maintain a Stripe-specific setting they likely don't think about — the window is **derived from the Tenant's actual Stripe payout schedule**, which Stripe's Account API already exposes (`settings.payouts.schedule`: interval + delay days). `tenant_settings.stripe_payout_interval`/`stripe_payout_delay_days` (new, see `0001-phase-1-table-structures.md`) are synced from that API by this same job on every run — self-maintaining if a Tenant changes their payout schedule directly in their own Stripe dashboard, no separate sync mechanism needed. The grace period used for `missing_in_stripe_extract` is `stripe_payout_delay_days` plus a small safety margin (proposed: 2 days, covering the UTC-cutoff effect above and ordinary processing variance) — falling back to the platform default of **5 business days** only for a Tenant not yet synced (e.g. immediately after connecting Stripe, before this job's first run).

## Tier and cadence (resolved)

**NestJS, daily** — same category as AR Reconciliation (ADR-0023): no money movement, no restart-safety stakes, just extraction and comparison. Daily cadence is safe as a default even for a Tenant on a weekly or monthly Stripe payout schedule instead of daily — the job simply finds no new payout to check on the days none exists, which is harmless, versus a slower cadence potentially missing/delaying detection for Tenants who are on daily payouts.

## Open items

- Exact safety-margin width added on top of `stripe_payout_delay_days` (proposed: 2 days) isn't firmly tuned — a reasonable starting point, not a committed value.
- The exact default seed mapping of every current Stripe `balance_transaction.type` value to a bucket isn't enumerated in this ADR — the mechanism (`stripe_transaction_type_bucket`) is designed, not the specific seed data, which should be compiled against Stripe's current API reference at implementation time.
