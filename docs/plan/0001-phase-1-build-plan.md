# AIARAP — Phase 1 Build Plan

Sequencing for [docs/spec/0001-ar-ap-phase-1.md](../spec/0001-ar-ap-phase-1.md). Each milestone is meant to be independently shippable/demoable, building on what came before rather than requiring the whole phase to land at once.

**AP moved to Phase 2 in its entirety** — [ADR-0035](../adr/0035-ap-functionality-moved-to-phase-2.md) — not just sequenced after AR within this phase. This build plan below is now AR/cross-cutting only; Milestones 5–7 (the old AP work) have moved to a "Phase 2" section at the bottom, kept for reference rather than deleted. This supersedes this doc's earlier "AR before AP" framing (originally settled via [ADR-0021's Parking Lot](../adr/0021-parking-lot.md), item 11) — that framing assumed AP was still Phase 1 work, just built second.

## Milestone 0 — Foundation

Nothing else can be built or demoed without this.

- AWS account/infra baseline: VPC, RDS Postgres instance, deployment pipeline ([ADR-0005](../adr/0005-aws-as-default-cloud-provider.md)).
- Schema-per-tenant provisioning tooling: script/process to create a new Tenant's schema plus the shared `global` schema ([ADR-0004](../adr/0004-schema-per-tenant-isolation.md)).
- AWS Cognito integration for authentication; Tenant SSO/IdP federation as a configurable option ([ADR-0006](../adr/0006-identity-platform-aws-cognito-with-tenant-sso-option.md)).
- Core domain entities: Tenant, User, Contact, Access Request, Payer, Vendor (base records, no business logic yet).
- Custom fields infrastructure: `custom_fields JSONB` column + `tenant_custom_field_definitions` table, applied to the first entity that needs it ([ADR-0003](../adr/0003-custom-fields-via-jsonb.md)).
- SAP Integration Adapter seam stood up (even if only one extraction call wired end-to-end) — this is the seam the Testing Decisions section identifies as highest-leverage, so get it real early rather than mocked everywhere.

## Milestone 1 — Access & Identity

- Access Request flow: self-service signup (email domain match) or invite → Payer/Vendor Admin approval → User + Contact created together.
- Payer Admin / Vendor Admin permissions (approve/deny requests, manage own Users).
- Per-Tenant branded portal subdomain.

## Milestone 2 — AR Core (Invoice-to-Cash)

- SAP Invoice extraction.
- Guest Invoice lookup (Invoice No + Customer No + Amount), rate limiting/CAPTCHA, Payer Admin notification after repeated failures.
- Registered Payer account tied to SAP/Salesforce Customer ID, viewing all open Invoices.
- Payment Provider interface + Stripe implementation ([ADR-0001](../adr/0001-payment-provider-abstraction.md)); card registration via Stripe Elements/Checkout.
- Partial payments (unlimited count, Tenant-configurable minimum), immediate SAP write-back.
- Invoice PDF fetched live from SAP (preview/download).
- Credit Card reconciliation (gross/fee/net, per-transaction and daily aggregate).

**Demoable at this point**: a Payer can find and pay an Invoice end-to-end, SAP reflects it immediately.

## Milestone 3 — Product Catalog & Sales Orders

- Product data (SAP-sourced or uploaded): descriptions, images, UOM, labels.
- Payer-facing product catalog browsing + Sales Order creation.

## Milestone 4 — Tasks, Notifications & Customer Representative

Cross-cutting — useful once any Tenant-facing work exists, not specific to AP. (Originally framed as "pulled ahead of AP" — that framing predates ADR-0035; kept ahead of everything else regardless, since it's genuinely cross-cutting Phase 1 work now, not just relative to AP.)

- Customer Representative entity (`global` schema) + per-Tenant assignment table.
- Task creation/assignment (Tenant User or Customer Representative, exactly one assignee), subtasks, email-interaction capture.
- Notification Channel interface + Email implementation ([spec: Task/notification delivery](../spec/0001-ar-ap-phase-1.md)).

## Cutting across every milestone

- Testing seams (SAP/Salesforce Adapter, Payment Provider, Textract) built as fixtures alongside the first milestone that exercises them, not retrofitted later.
- Custom fields extended to each entity as it's built, not all at once up front.

## Phase 2 (deferred in its entirety — [ADR-0035](../adr/0035-ap-functionality-moved-to-phase-2.md))

Everything below was Milestones 5–7 of this Phase 1 plan until ADR-0035 moved all AP scope out. Kept here as forward-reference planning, not deleted — renumber/reactivate when AP work actually resumes; don't treat the milestone numbers below as still slotting into the Phase 1 sequence above.

### AP Bill Flow

- SAP Vendor extraction; Vendor banking details capture (Routing No, Account, SWIFT, Currency, Country, IFSC, IBAN).
- Bill capture: email + Textract, or Excel upload; held pending.
- Dynamic AP approval matrix: field definitions (Vendor Record/Bill Header/Bill Item Details), Excel upload, sequence-ordered first-hit matching engine, up to 3 approvers per row.
- Bill line-item approval UI; all-or-nothing push to SAP once every line clears.
- Vendor-facing Bill status/progress view.

**Demoable at this point**: a Vendor submits a Bill, it routes to the right approver(s) automatically, and a fully-approved Bill lands in SAP.

### RFQ / Procurement Flow

- RFQ creation (copied from SAP) and distribution to Vendor Contacts (email, no login) or in-portal for logged-in Vendors.
- RFQ response capture (Textract or direct entry): unit price, quantity, lead time, MOQ, scale-based pricing (tier table).
- Dynamic RFQ approval matrix (header-level, Vendor Record/RFQ Header fields only).
- Approval creates Purchase Requisition, Info Record, or Purchasing Contract in SAP as appropriate; scale pricing pushed as condition-record scale lines for Info Record/Purchasing Contract; Purchase Requisition uses flat price only.
- Purchase Requisition approval stays in SAP's native workflow (no platform build needed here beyond visibility).
- Purchase Order visibility: extraction (header, items, schedule lines, address), PDF/Excel export.

### ASN & Labels

- ASN submission for Vendors without EDI (API, Excel, manual entry) → Inbound Delivery in SAP.
- Label printing: ZPL file generation (direct Zebra) and BarTender-compatible XML/CSV generation, one fixed default template per label type (shipping, product).
