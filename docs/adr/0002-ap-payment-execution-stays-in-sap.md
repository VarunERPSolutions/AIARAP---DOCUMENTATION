# AP Payment Execution Stays in SAP

**Timing note ([ADR-0035](0035-ap-functionality-moved-to-phase-2.md))**: AP as a whole moved to Phase 2 after this ADR was written. This decision's substance is unaffected — still the right call whenever AP is actually built — only its timing changed.

Unlike the AR side, where the platform executes Payer payments directly via Stripe, AP does not build its own vendor payment execution (ACH/wire). The platform captures and maintains Vendor banking details (routing number, bank account, SWIFT, IBAN) and surfaces payment status/details, but the actual outbound payment to a Vendor is executed by SAP's native payment run (e.g. F110) — avoiding the cost and compliance surface of building a treasury-grade payment execution engine for AP.
