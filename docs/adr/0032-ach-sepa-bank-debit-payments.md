# ACH/SEPA Bank Debit Payments

This ADR reverses the spec's Out of Scope line **"ACH and SEPA payment methods (Phase 2)"** — both are now confirmed in-scope for Phase 1. Driven by lower processing costs than card interchange, and a self-service registration flow where the Payer authorizes their own bank account rather than the Tenant needing to arrange bank-level authorization on their behalf.

## Architecture: parallel to card infrastructure, not a generalization of it

`payer_payment_card`/`card_payment`/`card_payment_attempt` and the jobs built around them (Automatic Card Payment batch, Card Expiry Alert, Stripe Connect webhook sync) are left **completely untouched**. ACH/SEPA gets its own parallel set of tables — `payer_bank_account`, `bank_debit_payment`, `bank_debit_payment_attempt` — rather than generalizing the existing card tables into a payment-method-agnostic shape. Bank debits are different enough in kind (no expiry concept, method-specific verification/mandate requirements, multi-day settlement with a real return/NSF risk window cards don't have) that forcing them into the card tables' shape would have meant retrofitting every already-built card-payment ADR and job in this doc for no real benefit. See `0001-phase-1-table-structures.md` for the full DDL.

## Settlement semantics: optimistic, same as a card charge

Stripe reporting an ACH/SEPA debit as "succeeded" (`payment_intent.succeeded`/`charge.succeeded`) is treated as sufficient to write back to SAP immediately and mark the Invoice paid — the same treatment a card charge already gets — rather than waiting days for actual bank-side settlement confirmation before touching SAP. This is directly confirmed by Stripe's own docs: both events are documented as firing well before funds are actually final (ACH settles T+4 business days standard/T+2 on faster settlement; SEPA settles T+6). `bank_debit_payment.settlement_status` (`pending`/`settled`/`returned`) tracks the multi-day outcome separately, for visibility, but does not gate the SAP write-back.

**Verified against Stripe's current docs (parking lot item 48, resolved) — this turns out to be two different mechanisms, not one:**

- **Return is event-driven**: `charge.dispute.created` is what fires when a bank debit that already looked `succeeded` comes back — Stripe documents this exact scenario for ACH by name ("Stripe might receive an ACH failure from the bank after a PaymentIntent has transitioned to `succeeded`," with the Dispute's `reason` carrying `insufficient_funds`/`incorrect_account_details`/`bank_cannot_process`). SEPA's equivalent is a customer-initiated dispute — a "no questions asked" right for 8 weeks, or up to 13 months if claiming the debit was unauthorized. This can fire even after `settlement_status` already reached `'settled'` — SEPA's 13-month dispute window far outlasts its own 6-business-day settlement window, so `'settled'` isn't truly terminal.
- **Settlement confirmation is time-based, NOT event-driven**: Stripe has no distinct "funds now settled" webhook — it's a documented time expectation only. `settlement_status` reaches `'settled'` via a daily sweep checking elapsed business days since `charged_at` (ACH 4, SEPA 6) with no return having arrived, not a push notification.

A late return doesn't get its own reversal state machine — it flips the already-created `payment` row (linked via the new `payment.bank_debit_payment_id`, mirroring `payment.card_payment_id` exactly) to `status = 'reversed'`. `invoice.open_amount`'s existing derivation (`SUM(payment.amount WHERE status='posted')`) already excludes reversed rows, so the Invoice reopens automatically with no new derivation logic. The reversal also needs its own SAP write-back (reversing the original clearing) and an AR Clerk notification — same recipient-resolution pattern (`payer_company_code.accounting_clerk_user_id`) as every other AR Clerk alert in this doc.

Considered and rejected: waiting for actual settlement before ever touching SAP. Safer against ever reporting a since-reversed payment as posted, but means an ACH/SEPA Invoice sits open days longer than an equivalent card payment would — a real, avoidable UX/reporting inconsistency against every other payment path already built.

## Withdrawal limit: Payer self-declared, not a Tenant-configured policy

`payer_bank_account.self_imposed_limit_amount`/`_period`/`_currency` — set by the **Payer themselves** at bank-account-registration time, not a Tenant admin. This is deliberately simpler than `payer_card_payment_policy`: there is no `payer_bank_account_payment_policy` mirroring it (per-Company-Code/Invoice-Type authorization scoping). The Payer's own stated reason for wanting this cap is being able to tell their own bank a hard ceiling on what AIARAP will ever pull — a self-protection/bank-justification mechanism, not an operational risk-control policy the Tenant configures. Checked as a hard outer bound before any charge attempt.

## Method-specific handling

- **ACH**: no formal signed mandate requirement (Stripe still requires authorization language shown at registration, not a legal instrument). Verified via Stripe Financial Connections (Plaid-based, instant) or a micro-deposit fallback for banks Financial Connections can't reach — tracked via `verification_method`/`verification_status`.
- **SEPA**: legally requires a signed mandate before any debit — `sepa_mandate_reference`/`sepa_mandate_signed_at` (NULL for ACH). SEPA also carries its own 8-week no-questions-asked customer reversal right, a materially longer and more customer-favorable window than a card chargeback — reflected in why `settlement_status`/return handling isn't assumed final quickly.

## Update: minimum payment amounts, per Company Code and per method

Each payment method gets its own Tenant-configurable minimum (`company_code.minimum_card_payment_amount`/`minimum_ach_payment_amount`/`minimum_sepa_payment_amount`, plus matching `_currency` columns) — living on `company_code`, not `tenant_settings`. This is a rename-and-relocation of the pre-existing `tenant_settings.minimum_partial_payment_amount` (originally card-only despite its generic name, per spec story 12): moved to the same Company-Code grain as `company_code.down_payment_configured` (a Tenant with multiple Company Codes may want different thresholds per one), and split into three independently-tunable fields since card/ACH/SEPA fee economics genuinely differ by method and region.

## Update: Stripe Connect moved to per-Company-Code (reopens ADR-0020)

Raised while wiring up ACH/SEPA's own Stripe registration: **Stripe Connect moves from one account per Tenant to one account per Company Code.** A Stripe Connect Standard account is a genuinely separate underlying Stripe account, not just a tag — a Tenant with multiple Company Codes (separate legal entities, each with its own bank account) needs each to settle payouts independently, which a single Tenant-wide account can't do.

This reopens ADR-0020's core design, not just ACH/SEPA's own tables:

- `stripe_enabled`/`stripe_connected_account_id`/`stripe_disconnected_at`/`stripe_payout_interval`/`stripe_payout_delay_days` all move from `tenant_settings` to `company_code`.
- `global.tenant_registry`'s single-column `stripe_connected_account_id` routing pointer is replaced by `global.stripe_account_routing` (one row per Connected Account ID → `tenant_registry_id`), since a Tenant can now own several accounts to route from.
- `payer_payment_card` and `payer_bank_account` both gain a required `company_code` column — a PaymentMethod token is only valid within the one Company Code's Connected Account it was registered under, so `is_primary` and `allow_child_use` are now scoped per `(payer_id, company_code)` rather than per Payer alone, and a policy's own `company_code` (`payer_card_payment_policy`) is now enforced by a real composite FK to match its card's.
- Every Stripe-gated job (Automatic Card Payment Batch, Card Expiry Alert, Stripe Payout Reconciliation, and the new Automatic Bank Debit Payment Batch/Stripe Bank-Debit Webhook Sync below) re-scopes from "per Tenant" to "per Company Code."

See ADR-0020's own Update note for the full detail, and `0001-phase-1-table-structures.md` for the DDL.

## Update: Sales Order checkout integration — Tenant choice between holding the order or submitting with a Delivery Block

`sales_order.payment_method` (ADR-0029) now accepts `ach`/`sepa` alongside `credit_card`/`purchase_order`, reusing the existing Stripe-charge-then-FI-Down-Payment flow as-is (ADR-0029's optimistic treatment already matches this ADR's own). But the checkout flow's default — create the real SAP Sales Order **immediately** on a successful charge — is riskier for ACH/SEPA than for a card: fulfillment could already be moving before the charge is actually final, days later. A `credit_card` charge doesn't carry this gap; ACH/SEPA's optimistic settlement (this ADR's own core decision) means it does.

**Decision**: a new `company_code.bank_debit_order_confirmation_mode` lets a Tenant choose, per Company Code:

- **`hold_in_aiarap`**: the charge still happens immediately at checkout, but SAP order creation is deliberately deferred — `sales_order.status` sits at a new `held_pending_settlement` value until `sales_order_payment.settlement_status` reaches `'settled'`. The new **Sales Order Bank-Debit Confirmation Batch** job (event-driven off the Stripe Bank-Debit Webhook Sync) releases it: on settlement, triggers the deferred SAP creation call (`held_pending_settlement → pending_sap_creation → sap_created`, then the normal ADR-0029 flow); on a return, cancels the order (`status = 'held_payment_returned'`) — nothing downstream was ever created, so unlike a direct Invoice payment return there's no `payment` row to unwind.
- **`submit_with_delivery_block`** (default): the SAP Sales Order is created immediately as ADR-0029 originally designed, but with SAP's own **Delivery Block** (`sales_order.delivery_block_code`, mirroring VBAK-LIFSK) set — the order exists, but can't generate a Delivery. The same batch job clears it (SAP call via Java's synchronous integration API, ADR-0039) once settlement confirms; on a return, the block deliberately **stays in place** — a structural prevention of shipment, not just a notification someone has to act on in time — alongside `sales_order.fulfillment_hold_flagged_at`/`fulfillment_hold_reason` and the usual `payment.status = 'reversed'` + AR Clerk notification, specifically alerting whoever owns fulfillment on the Tenant side (not just AR), since a Sales Order — not just an Invoice — is implicated.

Both modes apply identically to ACH and SEPA (same underlying settlement-delay risk); neither applies to `credit_card` (no equivalent gap) or `purchase_order` (never charged at checkout).

**Delivery Block and Billing Block are both reason-coded dropdowns, not booleans** — matching real SAP (VBAK-LIFSK/FAKSK reference configurable reason tables, TVLS/TVFS-equivalent, not a plain flag), via new `delivery_block_reason`/`billing_block_reason` tables. Both are scoped per **Sales Order Type** (`order_type`) — a Tenant may want a different available set of block reasons per Order Type — same composite-key convention already used for `shipping_priority` (scoped by `sales_org`). `sales_order.billing_block_code` is general-purpose (any Tenant user/AR Clerk can set it for any reason, not exclusively tied to this flow) but pairs naturally with `delivery_block_code` for a `submit_with_delivery_block` order — a Tenant may not want billing generated either while payment is unsettled, not just shipment. Distinct from the pre-existing `payer_sales_area.billing_block`, which is a plain boolean at the master-data level (blocks an entire Sales Area, not one order) — real SAP's KNVV-FAKSD is genuinely just a flag, unlike VBAK-FAKSK.

## `self_imposed_limit_period = 'monthly'`: calendar month, evaluated live (resolved, parking lot item 49)

Calendar month (resets the 1st), not a rolling window — the standard, intuitive phrasing for a self-declared authorization limit, mirroring how consumer bank/card spending limits are almost universally calendar-based. Evaluated live at each charge attempt: sum the bank account's own successful (non-returned) `bank_debit_payment` amounts from the 1st of the current calendar month through now, and skip the charge if adding it would exceed `self_imposed_limit_amount`. No separate tracking table mirroring `card_payment_threshold_exceeded` — that exists specifically for the card threshold check's FX-conversion complexity (persistent daily re-evaluation across currencies), which doesn't apply here since the limit's own currency matches the bank account's. A failed check is just logged as a normal `bank_debit_payment_attempt` (`outcome = 'failed'`).

## Also resolved

**Fee comparison/business case (ACH/SEPA vs. card interchange)**: not AIARAP's to quantify. Each Tenant's own fee economics determine whether/how much they promote ACH/SEPA to their Payers — AIARAP builds and offers the capability platform-wide, but adopting it is each Tenant's own business decision, not a platform-wide business case to establish. See parking lot item 50.

**Whether the Sales Order Bank-Debit Confirmation Batch needs a periodic safety-net sweep**: yes, but it guards against a *downstream reaction failure* (the release/delivery-block-clearing action never firing after `sales_order_payment.settlement_status` resolves), not a missed settlement/return signal — that signal is already resilient by construction (see above). See parking lot item 53 and `0002-scheduled-jobs.md`.
