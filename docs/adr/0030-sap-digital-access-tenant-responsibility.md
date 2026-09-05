# Third-Party Platform Licensing/Capacity Exposure: SAP Digital Access (Tenant Responsibility) + Salesforce API Limits (AIARAP-Provided Estimate)

Every AIARAP feature that calls a Tenant's SAP system to **create** a licensable document — starting with Sales Order checkout (ADR-0029), and applicable to any future feature with the same shape — carries SAP Digital Access licensing exposure for that Tenant (see parking lot item 41 for the underlying mechanics and the *SAP UK Ltd v Diageo Great Britain Ltd* [2017] EWHC 189 (TCC) precedent). This exposure exists regardless of which SAP API technology AIARAP uses (OData, BAPI, RFC, or otherwise) — it is a function of what the call does (creates a Sales Order, a Purchase Order, etc.), not how it's called.

## Decision: Tenant's contractual responsibility, not AIARAP's

This is codified as a standard clause in AIARAP's customer (Tenant) contract:

- The Tenant is responsible for confirming, **in writing from their own SAP account representative**, that they hold adequate Digital Access (or equivalent Named User) licensing coverage for the SAP document volume AIARAP's platform will create on their behalf, before enabling any feature with this shape (Sales Order checkout being the first instance).
- **AIARAP bears no responsibility or liability** for a Tenant's SAP licensing compliance, coverage adequacy, or any dispute/claim SAP may bring against the Tenant arising from AIARAP-originated document creation.
- This is distinct from — and does not replace — the existing technical prerequisite gate on this feature (`company_code.down_payment_configured`, ADR-0029), which governs whether the *SAP configuration* supports the checkout flow's FI Down Payment posting. Digital Access licensing is a separate, contract-level concern.

## Enforcement: contract clause only, no schema/DB gate

Deliberately **not** tracked as a schema-level flag (no `tenant_settings.digital_access_confirmed_at`/`_by` or equivalent) — unlike `company_code.down_payment_configured`, which blocks checkout at the application layer. This is a legal/contractual matter handled through the sales and legal onboarding process, not a system-enforced technical gate. The distinction matters: `down_payment_configured` verifies something AIARAP's own platform depends on functioning correctly (the FI Down Payment posting will simply fail if it's wrong); Digital Access coverage is a Tenant-SAP contractual relationship AIARAP has no visibility into and no technical means of verifying.

## Salesforce API rate limits: a different shape of risk, AIARAP provides the estimate upfront

Salesforce doesn't carry SAP's Digital Access-style indirect-use licensing risk — access from AIARAP's Salesforce AppExchange package (ADR-0027) authenticates via a Salesforce **Integration User License** (a purpose-built, lower-cost license type for system-to-system API access, distinct from a full UI seat), and Salesforce has no equivalent public litigation history over indirect access the way SAP does. The real constraint on the Salesforce side is different in kind: a **daily API call limit** per org, sized by edition and number of user licenses — a technical governor limit, not a contractual "indirect use" claim.

**Decision**: unlike the SAP clause above (Tenant-driven confirmation, AIARAP bears no responsibility), AIARAP takes the **affirmative obligation** here — during onboarding, before enabling any Salesforce-integrated feature for a Tenant, AIARAP provides the Tenant a **written estimate of expected Salesforce API call volume** (daily/monthly), computed from the specific features and sync jobs being enabled for that Tenant (extraction frequency × record volume, per `0002-scheduled-jobs.md`'s existing job catalog). This lets the Tenant proactively confirm or purchase sufficient API allocation with Salesforce *before* going live, rather than discovering a capacity shortfall only after hitting governor limits in production — the "no surprise" principle driving this decision.

This is narrower than the SAP clause's full liability disclaimer: AIARAP is responsible for providing an **accurate estimate** based on the features/volume actually configured, but not for the Tenant's decision not to act on it, nor for actual usage exceeding the estimate due to the Tenant's own subsequent business growth or newly added integration volume beyond what was originally scoped and estimated.

## Open items

- Exact contract clause language (SAP side) — to be drafted with legal counsel, not specified here.
- Whether the SAP clause should extend to a written disclosure/acknowledgment step during Tenant onboarding (a process checklist item, not a schema gate) — not yet decided.
- Exact formula/methodology for computing the Salesforce API call estimate (which sync jobs count, how record volume is projected for a not-yet-live Tenant, safety margin above the raw estimate) — not yet designed.
- Whether the Salesforce API call estimate needs to be recalculated and re-communicated when a Tenant later enables an additional Salesforce-integrated feature, or only once at initial onboarding.
- Current exact Salesforce API limit formula and Integration User License terms — verify against Salesforce's live documentation before this is used to compute a real estimate for a Tenant; not authoritative from memory alone.
