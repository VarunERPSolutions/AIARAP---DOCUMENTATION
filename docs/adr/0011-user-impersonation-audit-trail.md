# User Impersonation with Audit Trail

AIARAP supports "login as" impersonation for support purposes, scoped narrowly and fully audited rather than being a general-purpose capability.

## Who can impersonate whom

- **AIARAP Customer Representative** (must be assigned to that specific Tenant, per the `global`/Tenant-schema assignment relationship in [ADR-0004](0004-schema-per-tenant-isolation.md)) can impersonate:
  - A **Tenant User** — routine account support, no upfront reason required.
  - A **Payer or Vendor User** — a higher trust boundary (the Tenant's own outside customers/suppliers), requiring an upfront reason (e.g. referencing the reported issue/Task) before the session can start. Typical case: a Tenant's customer or vendor reports a bug, and the Customer Representative impersonates them to reproduce and understand it.
- **Tenant User holding a dedicated Permission** ("Impersonate Payer/Vendor User", assigned via Role by Tenant Admin per [ADR-0010](0010-security-roles-authorization-objects.md)) can impersonate a **Payer or Vendor User** for the same reason (investigating a reported issue) — not other Tenant Users. This Permission is unscoped (no Authorization Object) for Phase 1; scoping which specific Payers/Vendors a support Tenant User can impersonate is deferred until a real need for it shows up.

## Session mechanics (uniform regardless of who initiates)

- A reason is required whenever the impersonation target is a **Payer or Vendor User**; not required when the target is a Tenant User.
- The initiator specifies the desired session duration at start time, **capped at a maximum of 60 minutes**; the session auto-expires at that point rather than staying active indefinitely.
- The impersonated User receives **no notification** (no email) that their account was accessed.
- The audit trail is visible to **AIARAP and the Tenant Admin** — not to Payer/Vendor Admins, and not to the impersonated User themselves.

## Data model

Lives in each Tenant's own schema, consistent with "a Tenant's schema is the complete picture of that Tenant" ([ADR-0004](0004-schema-per-tenant-isolation.md)):

```sql
impersonation_session (
  id,
  initiator_customer_rep_id,   -- nullable FK into global.customer_representative
  initiator_tenant_user_id,    -- nullable FK into this Tenant's own user table (exactly one initiator column set)
  impersonated_user_id,
  reason,                      -- required if impersonated_user_id is a Payer/Vendor User
  requested_duration_minutes,  -- <= 60
  started_at, expires_at, ended_at
)

impersonation_action_log (
  id, impersonation_session_id REFERENCES impersonation_session(id),
  action_type, entity_type, entity_id, occurred_at
)
```

`impersonation_action_log` is populated at the middleware level — every mutating request made while a session is active is recorded — rather than adding an "acted via impersonation" column to every business table across the app (an impersonation-specific concern, not a system-wide audit-log redesign).
