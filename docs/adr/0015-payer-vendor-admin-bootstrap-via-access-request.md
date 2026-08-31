# Payer/Vendor Admin Bootstrap via Access Request Routing

Closes a gap in the existing Access model (`CONTEXT.md`): routing an Access Request to "the relevant Payer/Vendor Admin" assumes one already exists, but a brand-new Payer/Vendor relationship starts with zero Users — there's no one to route the very first request to.

## Identity vs. role, for context

AWS Cognito ([ADR-0006](0006-identity-platform-aws-cognito-with-tenant-sso-option.md)) only handles authentication — verifying an identity and issuing a token (`sub`) — it has no concept of AIARAP's own Roles (ADR-0010). A User record in AIARAP's own database stores a reference to the Cognito identity alongside its Role assignments; Cognito answers "who is this," AIARAP's own data answers "what can they do." Whether someone ends up a Payer/Vendor Admin or a regular User is entirely an AIARAP-side Role assignment, decided by the approval routing below — never something Cognito (or a Tenant's own SSO) determines.

## Access Request now carries a requested access type: Admin or User

- **If zero Users/Admins currently exist for that Payer/Vendor** (a brand-new relationship): the Access Request — whatever type it requests — routes to a **shared pool of Tenant Users holding a dedicated Permission** ("Approve Payer/Vendor Admin Bootstrap Requests", assignable via Role per [ADR-0010](0010-security-roles-authorization-objects.md)), not hardcoded to Tenant Admin specifically. Whoever in that pool acts on it first handles it — there's no field-based matching criteria needed here (unlike the AP/RFQ approval matrix), since the only condition is "no Admin exists yet for this Payer/Vendor." If the request is for Admin access and gets approved, that person becomes the Payer's/Vendor's first Admin.
- **Once at least one Admin exists** for that Payer/Vendor: the self-service **Admin-access request option is no longer offered at all** — only User-access can be requested, routed to the existing Payer/Vendor Admin exactly as today. Anyone who wants Admin access at that point has to ask an existing Admin directly, outside the system (offline) — there is no in-app request path for it once an Admin already exists.
- This routing rule applies uniformly regardless of how the Access Request originated — self-service signup, invite, or the Tenant-initiated bulk-onboarding path ([ADR-0014](0014-tenant-managed-payer-vendor-user-onboarding-offboarding.md)) — same underlying Access Request record, same rule.

This avoids requiring Tenant Admin specifically to proactively seed every new Payer/Vendor's first Admin ahead of time (rejected as too much manual work), and avoids hardwiring bootstrap approval to the Tenant Admin role at all — any Tenant User a Tenant Admin trusts with this Permission can handle it reactively, when an actual first request shows up.
