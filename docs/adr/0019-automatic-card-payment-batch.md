# Automatic Card Payment Batch: Success and Failure Handling

A new scheduled job, the **Automatic Card Payment batch**, sweeps every Tenant's open Invoices and auto-collects payment by stored credit card where the Payer has authorized it — rather than waiting for a Payer to log into the portal and pay manually. This ADR records the job's tier, its success/failure state machine, and where each outcome is recorded.

## Eligibility check (per open Invoice)

For each open Invoice, resolve its Payer, then:

1. Find that Payer's `payer_payment_card` row(s) (`status = 'active'`) — including a parent Payer's card where `allow_child_use = true` and `payer_hierarchy` currently links the Invoice's Payer as a child (any Sales Org/Distribution Channel/Division, `valid_to IS NULL OR valid_to > today`).
2. For each candidate card, find a matching `payer_card_payment_policy` row: same `payer_payment_card_id`, `invoice_type` matches the Invoice's type, `status = 'active'`, and today falls within `valid_from`/`valid_to`.
3. Charge only if the Invoice's open amount is `<= policy.max_amount_per_charge`. If the Invoice's currency differs from `policy.max_amount_currency`, convert using **today's rate from `currency_exchange_rate`** (rate_type `'M'`, the Tenant's own SAP-configured rate — same source the Currency Exchange Rate Extraction job already populates daily) before comparing (parking lot item 1, **resolved**).

No matching card/policy at all ⇒ the batch skips that Invoice entirely (no attempt is logged, nothing is tracked) — this Invoice simply isn't eligible for auto-pay by construction, it isn't an exception to flag. A matching card/policy that fails the *threshold* check specifically — either because the (converted) amount exceeds `max_amount_per_charge`, or because no exchange rate was available to even attempt the conversion — is different: it's upserted into `card_payment_threshold_exceeded` (see `0001-phase-1-table-structures.md`) rather than silently skipped, and drives the new Card Payment Threshold Alert job below.

## Threshold-exceeded tracking and daily alert (resolved)

`card_payment_threshold_exceeded` is upserted (keyed on `(invoice_id, policy_id)`) every batch run for any Invoice that has a matching card/policy but fails the threshold check — `skip_reason` distinguishes a genuine over-threshold amount from a missing exchange rate (the latter meaning eligibility couldn't even be determined). `resolved_at` is set once a later run no longer detects the condition (the Invoice was paid another way, the policy's threshold was raised, or an exchange rate became available) — rows are kept, not deleted, as an audit trail rather than a live-only flag.

A new, separate **Card Payment Threshold Alert** job (NestJS, daily) queries `card_payment_threshold_exceeded WHERE resolved_at IS NULL`, groups by the affected AR Clerk (`payer_company_code.accounting_clerk_user_id`, same recipient mechanism as the SAP write-back failure alert below), and sends one daily digest notification per Clerk via the Notification Channel ([ADR-0026](0026-notification-channel.md), `notification_type = 'card_payment_threshold_exceeded'`) — repeating every day the condition persists, same "no already-alerted flag needed, the underlying condition self-resolves" convention as the Credential Expiry Alert and Card Expiry Alert jobs. Kept as its own job rather than folded into the Automatic Card Payment batch itself, separating "detect and flag" (Spring Batch, money-movement-adjacent) from "notify" (NestJS, no money-movement stakes) — same tier-separation reasoning already applied elsewhere in this domain.

## Job tier: Spring Batch, not NestJS

Per [ADR-0039](0039-sap-integration-technology-and-backend-stack.md)'s tiering rubric (NestJS for frequent/incremental/lightweight work, Java + Spring Batch for heavy work needing chunk/checkpoint/restart), this job goes to **Spring Batch** — an exception to its per-invoice volume being lower than the nightly bulk SAP extraction job that originally justified that tier. The deciding factor is money movement: a mid-run crash must never double-charge an Invoice on restart, and Spring Batch's chunk/checkpoint/restart machinery is exactly the guarantee needed here, ahead of raw throughput.

## Success path

1. Charge the card via the Payment Provider interface ([ADR-0001](0001-payment-provider-abstraction.md)).
2. Insert a `card_payment_attempt` row (`outcome = 'succeeded'`) — the insert-only audit trail of every attempt, win or lose (see `0001-phase-1-table-structures.md`).
3. Insert a `card_payment` row (`sap_posting_status = 'pending'`), and set the attempt's `card_payment_id` to point at it.
4. Attempt the SAP write-back (payment/clearing posting).
   - **Succeeds** → `sap_posting_status = 'posted'`, `sap_posting_reference` set. Done.
   - **Fails** → increment `sap_posting_attempts`, record `sap_posting_last_error`, retry with backoff.

## SAP write-back failure: fixed retries, then notify the Payer's AR Clerk

The SAP write-back is retried **3 times**, within the same batch run, with exponential backoff (30 seconds, 2 minutes, 10 minutes between attempts) — sized for a transient SAP connectivity blip or momentary lock, not a same-day retry across separate scheduled runs, since money is already collected and closing the SAP bookkeeping gap sooner is preferable to waiting for tomorrow's run. If all 3 attempts fail, `card_payment.sap_posting_status` flips to `'failed'` and a Notification (Email, the existing Notification Channel) fires — not to the Payer, and not to a single Tenant Admin catch-all, but to **the specific Tenant employee responsible for that Payer's AR**.

This recipient was reconsidered twice:

1. **First draft: notify the Payer Admin** — rejected. The Payer's own payment already succeeded; the SAP posting failure is an internal Tenant-side bookkeeping gap the Payer has no ability to act on and arguably shouldn't be alerted to.
2. **Second draft: notify a single Tenant Admin** — rejected too. One Tenant can have many Payers; routing every write-back failure across all of them to one Admin inundates that person with alerts for accounts they may not even own.

**Resolved**: `payer_company_code.accounting_clerk_user_id` (new — see `0001-phase-1-table-structures.md`) is a direct FK to `app_user(id)`, replacing what was previously a flat SAP-mirrored `accounting_clerk` TEXT code. It's resolved via the failed `card_payment`'s `invoice_id` → that Invoice's Payer + Company Code → the AR Clerk assigned there. This maps notification load across whichever Tenant employees actually own each Payer's AR relationship, instead of concentrating it on one person — and since it's a direct FK rather than a Role lookup, it sidesteps the Security & Roles forward-reference gap entirely (unlike the Credential Expiry Alert job's recipient lookup in `0002-scheduled-jobs.md`, which does still depend on that domain).

**Fallback (resolved)**: `accounting_clerk_user_id` is nullable — a Payer's Company Code may have no AR Clerk assigned. The fallback notifies that Tenant's Admin(s), now resolvable via the minimal `role`/`user_role` slice pulled forward into the Tenancy & Identity domain (`0001-phase-1-table-structures.md`) specifically to unblock this: `SELECT app_user_id FROM user_role JOIN role ON role.id = user_role.role_id WHERE role.code = 'tenant_admin'`, scoped to that Tenant's schema (every query already is, schema-per-tenant). If a Tenant somehow has zero Tenant Admins — shouldn't happen given ADR-0010's bootstrap guarantee, but not structurally impossible — the notification has no recipient and this becomes an operational gap to monitor for, not a further code fallback.

Money is never at risk in this failure mode — Stripe already collected it — this is purely a bookkeeping/reconciliation gap between AIARAP's record (`card_payment`) and SAP's AR aging until someone posts it manually or a retry succeeds on a later run.

## Charge failure path (Stripe declines, etc.)

A `card_payment_attempt` row is inserted with `outcome = 'failed'`, `failure_code`/`failure_message` captured from the Payment Provider. No `card_payment` row is created, the Invoice remains open, and there is **no same-run retry** — hammering a just-declined card is avoided; the Invoice is naturally re-evaluated on the batch's next scheduled run.

### Repeated failure threshold: auto_pay_blocked (resolved)

A card that keeps failing shouldn't keep getting tried indefinitely across runs — `payer_payment_card.consecutive_failed_attempts` (new, see `0001-phase-1-table-structures.md`) increments on each failed attempt and resets to 0 on any success. Once it reaches `tenant_settings.card_auto_pay_max_failed_attempts` (new, Tenant-configurable, default 3), `auto_pay_blocked` is set and the card is excluded from future Automatic Card Payment batch runs.

This blocks **auto-pay only**, not the card outright — `auto_pay_blocked` is deliberately separate from `status`. A Payer can still see the card and retry it manually in the portal (they're present and can react to whatever's actually wrong — insufficient funds since resolved, a temporary issuer hold, etc.); full deactivation (`status = 'inactive'`) stays available as its own deliberate action, not an automatic side effect of unattended batch failures.

## Tables

New tables `card_payment` (successful payments — named generically, not `payer_card_auto_payment`, since Core AR/AP's future manual portal card payment flow is expected to write to the same table, distinguished by `initiated_via`) and `card_payment_attempt` (insert-only log of every attempt) are added alongside the Payer domain in `0001-phase-1-table-structures.md`, despite the Invoice domain (Core AR/AP) not being designed yet — `invoice_id` is a forward reference with no FK constraint until that domain exists.

## Open items

- Fallback notification recipient when `payer_company_code.accounting_clerk_user_id` is NULL (no AR Clerk assigned) — intended to be that Tenant's Admin, but the lookup depends on the not-yet-drafted Security & Roles domain (`user_role`/`role`).
