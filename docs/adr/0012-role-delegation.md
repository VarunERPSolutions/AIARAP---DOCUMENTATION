# Role Delegation

A User (Tenant, Payer, or Vendor — any of the three) can delegate one or more of their own Roles to another User for a set time period, self-service, with no Admin approval required.

- **Per-Role, not all-or-nothing**: the User picks which specific Role(s) to delegate, keeping any other Roles they hold non-delegated (e.g. delegating "AP Approver" while going on leave without also handing off an unrelated "Sales Order Create" Role).
- **Additive, not a hand-off**: the delegator keeps their own access to the delegated Role throughout the window — delegation only *extends* the Role to the delegate, it never suspends the delegator's own access. The delegate does not need to already hold the Role themselves; the delegation itself is what grants it, for the duration of the window.
- **Time-boxed**: an explicit start/end period set by the delegator when creating the delegation.
- **Scope**: available to Tenant Users, Payer Users, and Vendor Users alike — the mechanism is identical regardless of org type.

## Approval matrix interaction

The AP/RFQ dynamic approval matrix (spec Implementation Decisions) names specific individual Users as approvers on each row (up to 3, any one sufficing) — a direct reference to a person, not a Role check. Role delegation is wired into this: when checking whether a Bill/RFQ line's named approver(s) have approved, the check also treats an approval from anyone currently holding an **active delegation of the relevant approval-granting Role from one of those named approvers** as equivalent to the named approver's own approval. This is the actual driving use case for delegation — coverage for approval duties while someone is on leave — so delegation would be of limited value if it didn't reach into the approval matrix at all.

## Data model

Lives in each Tenant's own schema — Payer and Vendor Users also live there (Payer/Vendor being the Tenant's own customers/suppliers, per the domain hierarchy in `CONTEXT.md`), so no cross-schema complexity is needed regardless of which org type the delegator/delegate belong to:

```sql
role_delegation (
  id,
  delegator_user_id,
  delegate_user_id,
  role_id,
  starts_at, ends_at
)
```

A User's effective Roles at any point in time are the union of their directly-assigned Roles and any `role_delegation` rows where they are the delegate and the current time falls within `[starts_at, ends_at]`.
