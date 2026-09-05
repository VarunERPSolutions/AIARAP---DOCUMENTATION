# Stripe Payout Reconciliation

A new job extracts Stripe's daily payout details and verifies every AIARAP-originated transaction matches between `card_payment` and what Stripe actually settled — closing the loop between "Stripe told AIARAP the charge succeeded" (`card_payment`, [ADR-0019](0019-automatic-card-payment-batch.md)) and "Stripe actually paid it out to the Tenant's bank account."

**Update ([ADR-0032](0032-ach-sepa-bank-debit-payments.md))**: Stripe Connect is now one account per **Company Code**, not per Tenant (ADR-0020's reopened premise) — this job runs per Company Code, `tenant_settings.stripe_payout_interval`/`stripe_payout_delay_days` referenced below are now `company_code.stripe_payout_interval`/`stripe_payout_delay_days`, and a Tenant with multiple Company Codes gets independent payout reconciliation runs (and independent payout schedules) per one, not a single Tenant-wide run. Everything else below — bucketing, FX handling, discrepancy types, UTC-cutoff timing — is unchanged, just re-scoped.

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

**NestJS, daily** — same category as AR Reconciliation (ADR-0023): no money movement, no restart-safety stakes, just extraction and comparison. Daily cadence is safe as a default even for a Company Code on a weekly or monthly Stripe payout schedule instead of daily — the job simply finds no new payout to check on the days none exists, which is harmless, versus a slower cadence potentially missing/delaying detection for Company Codes on daily payouts.

## Default seed mapping (resolved, parking lot item 29)

Compiled against Stripe's current `balance_transaction.type` API reference. Each bucket's reasoning:

| Bucket | Stripe types | Reasoning |
|---|---|---|
| `charge` | `charge`, `payment` | Same economic event (money in from a customer) — old vs. PaymentIntents-era naming |
| `refund` | `refund`, `payment_refund`, `payment_failure_refund`, `application_fee_refund` | Grouped by "money moving back to the customer/counterparty," regardless of which specific flow triggered it |
| `fee` | `application_fee`, `stripe_fee`, `stripe_fx_fee`, `tax_fee` | Costs deducted by Stripe or the platform |
| `reserve` | `reserve_transaction`, `reserved_funds` | Funds Stripe holds back on risk grounds |
| `payout` | `payout`, `payout_cancel`, `payout_failure` | The actual settlement to the Tenant's bank |
| `adjustment` | `adjustment`, `payment_reversal`, `refund_failure` | Corrections that aren't cleanly a refund of a specific charge |
| `transfer` | `transfer`, `transfer_refund`, `transfer_cancel`, `transfer_failure`, `connect_collection_transfer` | Stripe Connect account-to-account movement |
| `other` | `topup`, `topup_reversal`, `advance`, `advance_funding`, `anticipation_repayment`, `contribution`, `climate_order_purchase`, `climate_order_refund`, `issuing_authorization_hold`, `issuing_authorization_release`, `issuing_dispute`, `issuing_transaction`, `payment_unreconciled` | Genuinely irrelevant to AIARAP's own integration (Stripe Capital/Climate/Issuing aren't products AIARAP uses) — seeded only defensively in case a Tenant's shared Connected Account carries unrelated activity from another system |

**Not authoritative forever** — Stripe adds `balance_transaction.type` values over time; verify against Stripe's live API reference before this seed data ships, same "verify at implementation time" treatment as other exact third-party specifics in this doc. `stripe_payout_transaction.transaction_type`'s FK means an unmapped new type fails extraction loudly rather than silently miscategorizing, so this list going stale is self-detecting, not a silent risk.

**Debit/credit G/L account fields, reference only, and per-bucket customer-routing**: `stripe_transaction_type_bucket` also carries `debit_gl_account`/`credit_gl_account` (which SAP G/L account a Tenant's finance team would use for this bucket, shown on the reconciliation view for their own manual journal entry) and `debit_posts_to_customer`/`credit_posts_to_customer` (real double-entry AR posting routes one side to the transaction's own Customer/Payer reconciliation account instead of a fixed G/L account — SAP KNB1-AKONT-style — and *which* side varies by bucket: a `charge` credits the Customer, reducing the receivable when payment arrives; a `refund` debits the Customer, reinstating it; `fee`/`reserve`/`payout`/`transfer`/`other` involve no Customer at all, both sides are fixed G/L accounts). These are seedable defaults for the customer-routing flags (universal accounting logic, not Tenant-specific); the actual G/L account *codes* are each Tenant's own chart of accounts, left blank for them to fill in — **this is reference data only, not an automated GL posting mechanism**. "Automated GL posting to SAP" remains explicitly Out of Scope for Phase 1 per the spec; no job reads these fields to actually post anything.

Also scoped per **Company Code**, not flat per Tenant — G/L accounts are genuinely Company-Code-specific in SAP (different legal entities have different charts of accounts), consistent with everything else that moved to Company-Code grain once Stripe Connect did (ADR-0020/0032). `stripe_payout`/`stripe_payout_transaction` both gained a `company_code` column as a result — a payout comes from exactly one Company Code's Connected Account, and `transaction_type`'s FK into `stripe_transaction_type_bucket` is now a composite `(company_code, transaction_type)` reference to match that table's new composite key.

## Open items

- Exact safety-margin width added on top of `stripe_payout_delay_days` (proposed: 2 days) isn't firmly tuned — a reasonable starting point, not a committed value.
