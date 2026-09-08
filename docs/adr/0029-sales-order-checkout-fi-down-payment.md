# Sales Order Checkout: Pricing Simulation, FI Down Payment, Real-Time SAP Order Creation

This ADR reverses two lines in the spec's Out of Scope section — **"Sales Order pricing/tax simulation in SAP"** and **"Sales Order replication to the ERP"** were both marked Phase 2, but both are now confirmed in-scope for Phase 1 as part of a single checkout flow. Spec updated accordingly (see below).

## Flow

1. Payer browses the Tenant's product catalog and builds a Sales Order in the AIARAP portal (no SAP call yet).
2. AIARAP calls SAP to **simulate pricing and tax** for the order as built — a live call, not a locally-computed estimate. No SAP document is created at this step.
3. Payer enters card details at checkout; AIARAP charges the simulated total via Stripe.
4. **Only on successful payment**, AIARAP calls SAP to **create the real Sales Order document**.
5. AIARAP posts the collected payment to SAP as an **FI Down Payment** (special G/L indicator, customer-level) — not an SD Down Payment (see below) — writing the exact SAP Sales Order number into the reference/assignment field (`BSEG-ZUONR`/`XREF1`) at posting time.
6. The eventual Invoice for this order arrives later through the **existing** Invoice extraction job, whenever the Tenant's own SAP billing cycle produces it (delivery-related or order-related billing — unchanged, no new sync mechanism). AIARAP matches it via `invoice_line.sales_document = sales_order.sap_sales_order_id` (both fields already exist in `0001-phase-1-table-structures.md`) and **itself drives/verifies the down payment clearing** against that Invoice, rather than leaving it to SAP's native automatic clearing.

## Why FI Down Payment, not SD Down Payment

Both were evaluated against real prior experience with each:

- **SD Down Payment** (billing-plan-based, configured at the Sales Order header) is structurally a **percentage of net order value** — a poor fit regardless of its known tax-proration issues (mixed tax rates/jurisdictions across lines don't prorate cleanly against a flat header percentage), since this checkout flow collects the *full* simulated total at checkout, not a deposit percentage.
- **FI Down Payment** (special G/L posting against the Customer account via a down payment request) takes an arbitrary amount — a natural fit for "charge exactly what Stripe collected." Its known weakness is **misapplication at clearing time**: because the posting lives in the Customer's general open-item pool rather than being structurally tied to one Sales Order, a manual clerk clearing it against the wrong open item is a real, previously-encountered failure mode.

AIARAP is positioned to eliminate that specific failure mode rather than inherit it: it knows the exact SAP Sales Order number *before* it posts the down payment, writes that number into the posting's own reference field, and drives the clearing match itself off the same `sales_document`/`sap_sales_order_id` key already used elsewhere in the schema — removing the human-judgment step that caused misapplication previously. Building an AIARAP-invented settlement mechanism that bypasses SAP's own down payment concept entirely was also considered and rejected — SAP already has a compliant, audit-friendly A/R down payment mechanism, and duplicating GL-posting logic outside it isn't consistent with "SAP/Salesforce remain systems of record; AIARAP never owns the books" (spec, Out of Scope).

## Failure handling: SAP order creation fails after a successful charge

If the SAP Sales Order creation call (step 4) fails after the card has already been charged, AIARAP retries **3 times with exponential backoff (30s, 2min, 10min)** — the exact same schedule as ADR-0019's Automatic Card Payment batch SAP write-back retry (`card_payment.sap_posting_status`/`sap_posting_attempts`/`sap_posting_last_error`), reused here since it's the same shape of situation: money already collected, needing a resilient retry before escalating to a human (parking lot item 40, resolved). If still failing after the last retry, the Sales Order is flagged (`sap_creation_failed`) and routed to the **AR Clerk** (`payer_company_code.accounting_clerk_user_id`, same recipient resolution used elsewhere) for manual resolution — investigate and either complete the SAP creation manually or issue the refund. No automatic refund fires without a human looking at it first, since some failures are data problems fixable without ever needing to reverse the charge.

## Tenant/Company Code prerequisite: FI Down Payment configuration, gated per Company Code

Whether FI Down Payment (special G/L indicator + alternative reconciliation account) is correctly configured is a **Company Code**-level SAP configuration fact, not a Tenant-wide one — a Tenant with multiple company codes (e.g. a subsidiary onboarded later) can easily have it configured in one and not another. This promotes `company_code` (previously plain `TEXT`, uncatalogued anywhere) into a first-class tenant-level reference table (SAP T001-equivalent, same "promote once it needs to carry real config" treatment `invoice_type` already got):

```sql
CREATE TABLE company_code (
    code                       TEXT PRIMARY KEY,  -- SAP BUKRS
    name                       TEXT NOT NULL,
    down_payment_configured    BOOLEAN NOT NULL DEFAULT FALSE,  -- FI special G/L indicator + recon account confirmed set up for this company code
    down_payment_verified_at   TIMESTAMPTZ,   -- when AIARAP last confirmed the config (manual verification step, not self-service — same treatment as stripe_enabled only being flipped after Stripe Connect onboarding is confirmed)
    down_payment_verified_by   UUID,
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                 UUID,
    updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                 UUID
);
```

Checked against `sales_order.company_code` at checkout time — a Sales Order can only proceed through checkout for a company code with `down_payment_configured = TRUE`.

**Retrofit**: existing plain-`TEXT` `company_code` columns are promoted to real FKs against this table, consistent with how `invoice_type` was already treated rather than left as free text once it needed to carry data:
- `payer_company_code.company_code` → `REFERENCES company_code(code)`
- `invoice.company_code` → `REFERENCES company_code(code)`
- `payer_card_payment_policy.company_code` → `REFERENCES company_code(code)`

(DDL for these three ALTERs, plus the new `product`/`sales_order`/`sales_order_line`/`sales_order_payment` tables, to be written into `0001-phase-1-table-structures.md` table-by-table.)

## Update: second payment method — Purchase Order (bill-on-account, net terms)

Alongside `credit_card`, `sales_order.payment_method` also supports `purchase_order` — approved customers can check out with no payment collected at all, settling later through normal AR under their existing `payer_company_code.payment_terms`. This is gated by a new `payer_company_code.po_order_allowed` flag (manually approved, `po_order_approved_at`/`_by` — not self-service, same treatment as `company_code.down_payment_verified_at`). A `purchase_order` order skips the entire payment/FI-Down-Payment mechanic this ADR was built around — it goes straight from `pricing_simulated` to SAP order creation (`pending_sap_creation`, renamed from `paid_pending_sap_creation` since nothing is "paid" on this path), and no `sales_order_payment` row is ever created for it — that table now covers every money-collecting method, not `credit_card` alone. ACH was considered alongside this but held back at the time — it later came into Phase 1 scope via [ADR-0032](0032-ach-sepa-bank-debit-payments.md), which also extended this table's `payment_method`/`sales_order_payment`/`status` design to accommodate ACH/SEPA's own settlement-delay risk (the `held_pending_settlement`/`held_payment_returned` statuses, `delivery_block_code`/`billing_block_code`, and the Tenant-configurable hold-vs-delivery-block choice all come from that update, not this one).

## Update: catalog browsing needs an indicative price, since pricing is never stored for real

A real gap in the original design: this ADR deliberately never computes or stores pricing locally — the authoritative price always comes from the live `BAPI_SALESORDER_SIMULATE` call once something is added to a cart. But that left catalog *browsing*, before anything is in a cart, with no price to show at all.

**Decision**: a new **List Price Extraction** job (daily, NestJS, same tier as Currency Exchange Rate/Invoice Type Extraction) populates two indicative price levels — `product_sales_org.list_price` (general, per Sales Org/Distribution Channel) and `product_payer_price` (a more specific Customer-level override, checked first when it exists, SAP Customer-Material-Info-Record-equivalent). Both are explicitly **indicative only** — the real, final price a Payer actually pays always still comes from re-simulating once the product is added to a cart, and can legitimately differ (scale discounts, promotions, tax). See `0002-scheduled-jobs.md` for the full job design.

(Product master data itself — `product`/`product_sales_org`/`product_uom`, the fields *this* pricing addition builds on top of — is extracted separately, folded into the existing Nightly Bulk SAP Extraction batch, ADR-0039. See that ADR and `0002-scheduled-jobs.md`'s Product Extraction detail.)

**No scale/quantity-break pricing modeled** — deliberately kept to one flat indicative number per price level, not the RFQ domain's scale-pricing child-table pattern (base price + price-break tiers). Adding quantity-based tiers to the indicative catalog price would complicate the display for a number that's already only approximate — any real quantity-based break SAP applies is invisible here regardless and only surfaces once the live simulation actually runs against the cart's real quantity.

## Update: Schedule Lines, display-only

`sales_order_schedule_line` (SAP VBEP-equivalent) is populated entirely from the same live pricing/tax simulation call that fills `sales_order_line`'s own amount columns — when SAP's availability/ATP check splits a line's quantity across multiple confirmed delivery dates, AIARAP stores and shows each split as-is. Display-only, no write path back to SAP, same "SAP is the authority" principle already applied to pricing/tax/account-assignment elsewhere in this flow. An insert-only snapshot — re-simulating the order replaces a line's schedule lines wholesale rather than updating them in place.

## Also resolved

**Exact SAP API/BAPI for the pricing/tax simulation call**: `BAPI_SALESORDER_SIMULATE` (dry-run, creates no document). S/4HANA OData fallback still unverified — see parking lot item 37.

**Exact SAP API/BAPI for real-time Sales Order creation**: `BAPI_SALESORDER_CREATEFROMDAT2`. S/4HANA OData fallback (`API_SALES_ORDER_SRV`) still unverified — see parking lot item 38.

**AR Reconciliation (ADR-0023) and AR Aging (ADR-0024) accounting for FI Down Payment postings**: visible in both, but never blended into the existing numbers — `ar_reconciliation_account.pending_down_payment_amount` (additive visibility only) and `ar_aging_snapshot_down_payment` (a separate summary, never folded into any aging bucket). See ADR-0023, ADR-0024, and parking lot item 39.

**Exact retry count/backoff schedule for the SAP order-creation failure path**: 3x/30s-2m-10m, same as ADR-0019 — see parking lot item 40.
