# Employee Offboarding: Bulk Transaction Reassignment

When a Tenant employee (Tenant User) leaves the organization, everything they currently own/are assigned/are named on needs to move to another active employee — without altering the historical record of what they actually did while employed.

## What gets reassigned

- **Bill Owner** (the Owner field introduced for Bills)
- **RFQ Response Owner** (the Owner field introduced for RFQ responses)
- **Task assignee**
- **Approval matrix named-approver rows** — the AP/RFQ dynamic approval matrix's rows that name the departing employee as one of up to 3 approvers ([spec Implementation Decisions](../spec/0001-ar-ap-phase-1.md))

## Mechanism: independent bulk actions, not one combined workflow

Each of the four is its own **independent bulk-reassignment action**, not steps in a single combined "offboard this employee" wizard — they can be run separately, at different times, by whoever handles that category.

- **Bill Owner, RFQ Response Owner, and Task assignee** each further split by **open vs. closed** status (each object type has its own lifecycle), and each split can go to a **different target employee** — e.g. the departing employee's *open* Bills go to whoever is picking up their live workload, while *closed* Bills might go to a different records custodian, since there's no ongoing work left to hand off on those.
- **Approval matrix rows** are standing routing configuration, not transactions with a status — there is no open/closed split for these. Reassignment is one flat action: every matrix row naming the departing employee is updated to name the new employee instead.
- Each bulk action operates on the **full matching set** for that (object type, status) combination — no manual pick-and-choose of individual records within a single run. If finer-grained splitting is ever needed, that's better served by running the action again with a different target than by adding a subset-selection UI.

## What never changes

The bulk action only updates the **mutable ownership/assignment field** on each record (Owner, the matrix row's approver reference, Task assignee). It never edits any **historical/audit field** — e.g. `approved_by`, `created_by`, or any other already-recorded fact about who actually performed a past action stays attributed to the departed employee exactly as it happened. Reassignment changes who is responsible for something *going forward*; it never rewrites what already happened.
