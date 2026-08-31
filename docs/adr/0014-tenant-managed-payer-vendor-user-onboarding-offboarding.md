# Tenant-Managed Payer/Vendor User Onboarding & Offboarding

Tenant Users can onboard and offboard Payer/Vendor Users, one at a time or in bulk via Excel upload — with different rules for each direction.

## Onboarding: stays within the existing Access Request flow

A Tenant User creating Payer/Vendor Users (individually or via bulk Excel upload) does **not** bypass the existing Access model (`CONTEXT.md`: Access Request → approved by the relevant Payer/Vendor Admin, never the Tenant). This is a Tenant-initiated, bulk-capable entry point into the **same** Access Request machinery already built — it creates pending Access Request(s) on the Payer's/Vendor's behalf, which still require that Payer's/Vendor's own Admin to approve before a User + Contact is actually created. The "never the Tenant approves" rule is unchanged; this only adds a faster way to originate the request.

## Offboarding: direct deactivation, gated behind a dedicated Permission

Offboarding is different — a Tenant User holding a dedicated **Permission** ("Offboard Payer/Vendor Users", assignable via Role per [ADR-0010](0010-security-roles-authorization-objects.md)) can directly **deactivate** a Payer/Vendor User, one at a time or in bulk via Excel upload — **including Payer/Vendor Admin accounts themselves**, not just regular Users. This extends what ADR-0010 already established for Tenant Admin (full create/change/delete authority over Payer Admin/Vendor Admin accounts): that authority is now understood as Tenant Admin holding this Permission by default, rather than a separate hardcoded special case — and the Permission can also be delegated by a Tenant Admin to other trusted Tenant staff (e.g. an ops/support team) without granting full Tenant Admin authority.

- **Deactivation, not deletion**: access is revoked, but the User/Contact record and all historical activity (RFQ responses submitted, email interactions tracked) stays intact and reversible — consistent with never destroying historical records elsewhere in this spec. A deactivated User can be reactivated later if needed.
- **Notification**: the affected Payer/Vendor Admin is notified (via the Notification Channel interface, Email in Phase 1) whenever a User in their own organization — including their own Admin account — is deactivated by the Tenant. Unlike impersonation (routine, temporary, internal), this is a permanent-until-reversed change directly affecting someone's ability to use the portal, so silent deactivation risks that org not noticing until something breaks.
