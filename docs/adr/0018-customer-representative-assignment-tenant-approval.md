# Customer Representative Assignment Requires Tenant Admin Approval

Assigning an AIARAP Customer Representative to a Tenant — populating `{tenant}.assigned_customer_representative` ([ADR-0004](0004-schema-per-tenant-isolation.md)) — requires that Tenant's own Admin to approve first, closing a governance gap in the original design: nothing previously stopped AIARAP from unilaterally granting its own staff access/impersonation rights ([ADR-0011](0011-user-impersonation-audit-trail.md)) into a Tenant's environment.

## Identity stays global; only assignment is gated

Customer Representative's own master record (name, email, employment status) remains the single global row in `global.customer_representative` — this decision does **not** turn Customer Representatives into per-Tenant Contacts/Users. A rep supporting 5 Tenants is still one row, not five: duplicating that identity per Tenant schema was considered and rejected, for the same reason ADR-0004 made it global in the first place — a name/email change or an offboarding at AIARAP would otherwise require updating N schemas instead of one. Reusing the Payer/Vendor tables themselves to carry this identity was also considered and rejected — it would overload their actual AR/AP meaning (a "list all Vendors" report should never include AIARAP/Varun ERP Solutions).

## Mechanism

A new `{tenant}.customer_representative_assignment_request` table, structurally similar in spirit to Access Request ([ADR-0014](0014-tenant-managed-payer-vendor-user-onboarding-offboarding.md)) but distinct from it — it gates only the assignment mapping, not a User/Contact creation:

```
customer_representative_assignment_request (
  id,
  customer_rep_id,     -- FK into global.customer_representative
  status,              -- pending / approved / denied
  requested_by,        -- AIARAP-side requester
  decided_by,          -- Tenant Admin who approved/denied
  decided_at,
  denial_reason
)
```

Only on approval is the corresponding `assigned_customer_representative` row created. A rep with no approved assignment for a given Tenant cannot initiate an impersonation session there (ADR-0011's initiator check now implicitly depends on this table).

## Revocation (resolved)

Symmetric with the approval gate, as expected, but implemented as a direct field-level deactivation rather than a mirrored "revocation request" table — same permission-gated-direct-action pattern as Payer/Vendor User offboarding ([ADR-0014](0014-tenant-managed-payer-vendor-user-onboarding-offboarding.md)), not a second approval workflow. `assigned_customer_representative` (see `0001-phase-1-table-structures.md`) carries `is_active`, `deactivated_by` (the Tenant Admin who acted, FK to `app_user`), `deactivated_at`, and `deactivation_reason` directly — a permissioned Tenant Admin flips `is_active := false` on the row, no new request/approval cycle needed since the original approval already established that Admin's authority over this rep's presence in their Tenant. Rows are soft-revoked with full history (who/when/why), never hard-deleted, consistent with "deactivation not deletion" elsewhere in the platform. Resolved as part of the Tenancy & Identity domain DDL pass; tracked in [ADR-0021's Parking Lot](0021-parking-lot.md) (item 10) until this confirmation.
