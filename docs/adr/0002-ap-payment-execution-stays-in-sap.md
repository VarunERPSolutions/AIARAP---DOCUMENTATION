# AP Payment Execution Stays in SAP

Unlike the AR side, where the platform executes Payer payments directly via Stripe, AP does not build its own vendor payment execution (ACH/wire). The platform captures and maintains Vendor banking details (routing number, bank account, SWIFT, IBAN) and surfaces payment status/details, but the actual outbound payment to a Vendor is executed by SAP's native payment run (e.g. F110) — avoiding the cost and compliance surface of building a treasury-grade payment execution engine for AP.
