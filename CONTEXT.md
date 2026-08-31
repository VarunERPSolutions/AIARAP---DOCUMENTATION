# AIARAP

A multi-tenant SaaS application, built and operated by Varun ERP Solutions, providing Accounts Receivable and Accounts Payable operations on top of Tenants' existing systems of record (e.g. SAP, Salesforce). The platform is not a general ledger or system of record for invoices — it extracts and acts on data owned by external ERP/CRM systems, and writes results back to them.

Organizational hierarchy: **AIARAP** (the platform, operated by Varun ERP Solutions) → **Tenant** (subscribes to AIARAP) → **Payer** / **Vendor** (the Tenant's own customers/suppliers).

## Language

**AIARAP**:
The SaaS product/platform itself, operated by Varun ERP Solutions. Sits above Tenant in the domain hierarchy — Tenants subscribe to AIARAP, not the other way around.

**Customer Representative**:
An AIARAP employee assigned to a Tenant as their point of contact — a customer-success/account-management role AIARAP provides to its Tenants. Distinct from any Tenant-side, Payer-side, or Vendor-side User. Tasks can be assigned to a Tenant's own Users or to the Customer Representative responsible for that Tenant's account.

**Tenant**:
A business that subscribes to the platform. Owns the external systems of record (SAP, Salesforce, etc.) that invoices are extracted from.
_Avoid_: Customer (ambiguous — see Payer)

**Payer**:
The Tenant's own customer organization — owes money on Invoices and pays them through the payment portal. Matches a SAP or Salesforce Customer ID. An organization, not an individual — see User and Contact for the people who act on its behalf.
_Avoid_: Customer, customer's customer, end customer, debtor

**User**:
An individual with login credentials (email, password, roles, MFA), belonging to exactly one Payer, Vendor, or the Tenant itself. Every User is a Contact; not every Contact is a User.

**Contact**:
The record of a person associated with a Payer or Vendor within the platform — used for RFQ distribution, task assignment, and email interaction tracking, independent of whether that person has login access. Becomes a User once invited/registered with credentials.

**Access Request**:
A pending request from a person to become a User under a specific Payer or Vendor, raised via self-service signup (matching email domain) or invite. Must be approved by that Payer's or Vendor's own Admin — never the Tenant — before a User and Contact are created. Tracked with status (Approved/Denied), reason for denial, timestamps, and IP address.

**Payer Admin** / **Vendor Admin**:
A User with the authority to approve/deny Access Requests and manage other Users within their own Payer or Vendor organization. Cannot create or manage any Admin account (including a peer Payer/Vendor Admin) — that authority belongs solely to Tenant Admin. Renamed from the document's "Customer Admin" to match the Payer/Vendor terminology.
_Avoid_: Customer Admin; "User Admin" (inconsistent terminology from the source document for this same role, not a distinct tier — see [ADR-0010](docs/adr/0010-security-roles-authorization-objects.md))

**Tenant Admin**:
A User with full create/change/delete authority over Payer Admin and Vendor Admin accounts for their own Tenant, and able to create additional Tenant Admins. The first Tenant Admin for a new Tenant is created by an AIARAP employee, not self-service. See [ADR-0010](docs/adr/0010-security-roles-authorization-objects.md).

**Invoice-to-Cash**:
The AR capability that extracts invoices from a Tenant's system of record, presents them to the Payer for payment via a hosted portal, collects payment (credit card or ACH), writes the cleared/paid status back to the Tenant's system of record, and provides reconciliation reporting by payment method. Covers every Invoice regardless of origin — including ones that never passed through this platform as a Sales Order.
_Avoid_: Order-to-Cash (broader industry term; not accurate here since most Invoices don't originate from a portal-created Sales Order)

**Sales Order**:
A request for products/services created by a Payer through the portal, submitted into the Tenant's system of record (SAP/Salesforce). Expected to generate an Invoice, which then flows through Invoice-to-Cash like any other Invoice. Most Invoices in the system do NOT originate from a Sales Order — they exist in the Tenant's system independently of this platform.

**Invoice**:
A billing document issued by the Tenant to a Payer, representing money owed TO the Tenant. AR-side only.
_Avoid_: Bill (that's the AP-side term — opposite direction of money flow)

**Vendor**:
A business organization that supplies goods/services to the Tenant and is owed money by the Tenant. The AP-side counterpart to Payer. Matches a SAP Vendor ID. Sourced exclusively from SAP (no Salesforce equivalent, since Salesforce has no procurement/vendor data model).
_Avoid_: Supplier (pick one term; Vendor matches SAP terminology)

**Bill**:
A billing document issued by a Vendor to the Tenant, representing money owed BY the Tenant to the Vendor. AP-side only. Unlike an Invoice, a Bill does not originate in SAP — it's captured by the platform (email/Textract or Excel upload), held pending approval, and only pushed into SAP once approved.
_Avoid_: Invoice (that's the AR-side term — opposite direction of money flow)

**ASN (Advance Shipping Notice)**:
A notification from a Vendor that goods against a PO have shipped (tracking numbers, expected delivery, packing details). Submitted through the portal (API, Excel, or manual entry) by Vendors who lack EDI capability to send ASNs directly to the Tenant's SAP. Creates an Inbound Delivery in SAP.

**Inbound Delivery**:
The SAP document created from an ASN, representing an expected goods receipt against a PO.

**Purchase Requisition**:
An internal request to purchase goods/services, created in SAP once a Tenant's Purchasing Team reviews and approves RFQ responses within the platform. One of three possible outcomes the Purchasing Team can choose at approval time — the others being an updated Info Record (standing price update) or a Purchasing Contract (longer-term agreement) — depending on the nature of the need. Triggers SAP's own native approval workflow (distinct from the platform's own dynamic approval matrix used for Bills and RFQ responses), which — once approved — results in a Purchase Order. Not yet a binding order to the Vendor.
_Avoid_: Purchase Order (that's the later, approved, binding document — extracted separately once SAP's workflow completes)

**Account Assignment**:
The combination of fields used to code a Bill line item for posting to SAP — Company Code, GL Account, Cost Center, (Internal) Order, WBS Element, and/or Vendor. Assigned at the line-item level: a single Bill can have multiple lines, each with its own Account Assignment. Account Assignment fields are typical (but not the only) choices a Tenant can use as matching criteria in the platform's own dynamic approval matrix — approval routing is a Tenant-configurable capability, not hardwired to Account Assignment specifically (see Implementation Decisions in [the Phase 1 spec](docs/spec/0001-ar-ap-phase-1.md)).
_Avoid_: Cost Object (imprecise — excludes Company Code and GL Account, which aren't Cost Objects in SAP terminology)
