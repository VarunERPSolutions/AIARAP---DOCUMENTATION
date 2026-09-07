# All AP Functionality Moved to Phase 2 (Reverses Spec Scope)

This ADR reverses course on a scope call the spec has carried since it was first written: **AP (Vendor payables — Bill capture/approval, RFQ/procurement, ASN, Vendor banking, the AP and RFQ approval matrices) is no longer part of Phase 1 at all.** It moves to Phase 2 in its entirety, not just later in the Phase 1 build order.

## What this is not

This is **not** the same thing as [parking lot](0021-parking-lot.md) item 11 ("AR before AP"), which only settled *sequencing within Phase 1* — AR ships first, AP ships after, but both were still Phase 1 work. This ADR removes AP from Phase 1 outright. Item 11's resolution is superseded by this one, not contradicted — "AR before AP" is now moot, since there's no AP milestone left in Phase 1 to sequence against.

## What doesn't change

- **AR is unaffected** — every AR user story, ADR, and table already built stays exactly as designed.
- **Design work already done for AP is preserved, not deleted.** User stories 17–31 (spec), the AP/RFQ approval-matrix and ASN implementation-decision bullets, Milestones 5–7 (build plan), and the already-built `vendor`/`vendor_company_code`/`vendor_purchasing_org`/`vendor_bank_account`/`purchase_org` DDL (schema doc) all stay in their documents, relabeled as Phase 2 reference material — re-deriving this design later would waste the thinking that already went into it.
- **[ADR-0002](0002-ap-payment-execution-stays-in-sap.md)** (AP payment execution stays in SAP's native payment run) is still the right call *whenever* AP is built — its substance doesn't change, only its timing.

## What actually moves

- Spec: User Stories 17–31 (`AP — Vendor-facing`, `AP — Tenant-facing`), and their corresponding Implementation Decisions (Bill flow, AP approval matrix, RFQ flow, RFQ approval matrix, Purchase Requisition approval, RFQ scale-based pricing, ASN flow, Vendor banking) — all now marked Phase 2 in place, not removed.
- Build plan: Milestones 5 (AP Bill Flow), 6 (RFQ/Procurement), 7 (ASN & Labels) move under a new "Phase 2" heading, out of the Phase 1 sequence entirely.
- Schema doc: the `vendor`/`purchase_org` family of tables (already-built DDL) gets a scope note — kept, not deployed/migrated as part of Phase 1.

## Open item: the ripple into Vendor-side access/security

Not resolved here, flagged instead: [ADR-0014](0014-tenant-managed-payer-vendor-user-onboarding-offboarding.md), [0015](0015-payer-vendor-admin-bootstrap-via-access-request.md), and [0016](0016-payer-vendor-admin-user-termination.md) are all written generically as "Payer/Vendor" — onboarding, admin bootstrap, and termination mechanics that apply equally to both. With AP entirely deferred, there's no Phase 1 feature for a Vendor User to actually use once they're onboarded — which raises a real question this ADR doesn't answer: should Vendor-side Access Requests/Admin bootstrap/User management also be excluded from Phase 1 (no point onboarding a Vendor User with nothing to do), or built anyway (since the mechanics are shared with Payer and cost little extra to leave in for both)? Left open rather than assumed either way — see parking lot.
