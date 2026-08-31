# Architecture Decision Records

Index of AIARAP's ADRs. Full spec: [docs/spec/0001-ar-ap-phase-1.md](../spec/0001-ar-ap-phase-1.md). Build plan: [docs/plan/0001-phase-1-build-plan.md](../plan/0001-phase-1-build-plan.md). Domain glossary: [CONTEXT.md](../../CONTEXT.md). **Every open/unresolved question across all of these lives in [0021 — Parking Lot](0021-parking-lot.md)** — check it before assuming something is undecided or forgotten.

| ADR | Decision |
|---|---|
| [0001](0001-payment-provider-abstraction.md) | AR payments: Stripe for Phase 1, behind a generic Payment Provider interface |
| [0002](0002-ap-payment-execution-stays-in-sap.md) | AP payment execution stays in SAP's native payment run (e.g. F110) — no vendor payment execution built in-platform |
| [0003](0003-custom-fields-via-jsonb.md) | Tenant custom fields: JSONB column + metadata table, not per-tenant schema drift |
| [0004](0004-schema-per-tenant-isolation.md) | Tenancy: schema-per-tenant Postgres isolation (reaffirmed vs. single-schema+RLS), plus a `global` schema for cross-Tenant entities (Customer Representative) |
| [0005](0005-aws-as-default-cloud-provider.md) | AWS as the default cloud provider |
| [0006](0006-identity-platform-aws-cognito-with-tenant-sso-option.md) | Identity: AWS Cognito by default, with per-Tenant SSO/IdP as an option |
| [0007](0007-rds-postgresql-over-aurora.md) | Database: AWS RDS PostgreSQL, not Aurora, at AIARAP's expected scale |
| [0008](0008-frontend-react-spa.md) | Frontend: React + TypeScript client-rendered SPA (Vite), not Next.js |
| [0009](0009-backend-nodejs-typescript.md) | Backend: Node.js + TypeScript (NestJS), not Java/Spring Boot |
| [0010](0010-security-roles-authorization-objects.md) | Security roles: fixed AIARAP-defined roles parameterized via SAP-style reusable Authorization Objects, with Tenant/Payer/Vendor Admin-created Derived Roles |
| [0011](0011-user-impersonation-audit-trail.md) | User impersonation ("login as"): AIARAP Customer Representative and permissioned Tenant Users, reason-gated for Payer/Vendor targets, 60-min max sessions, full action audit trail |
| [0012](0012-role-delegation.md) | Role delegation: self-service, per-Role, additive, time-boxed; wired into the approval matrix's named-approver check |
| [0013](0013-employee-offboarding-reassignment.md) | Employee offboarding: bulk-reassign Bill/RFQ Owner and Task assignee (split by open/closed, per-object-type), and approval matrix rows, without touching historical audit fields |
| [0014](0014-tenant-managed-payer-vendor-user-onboarding-offboarding.md) | Tenant-managed Payer/Vendor onboarding (stays in the Access Request flow) and permission-gated offboarding (direct deactivation, including Admins, with notification) |
| [0015](0015-payer-vendor-admin-bootstrap-via-access-request.md) | Payer/Vendor Admin bootstrap: Access Requests carry a requested type (Admin/User); routes to a permission-gated shared pool of Tenant Users when no Admin exists yet, otherwise Admin-access requests aren't offered |
| [0016](0016-payer-vendor-admin-user-termination.md) | Payer/Vendor Admin can deactivate regular Users in their own org (never a peer Admin); active Role Delegations involving the terminated User end immediately |
| [0017](0017-sap-batch-extraction-java-spring-batch.md) | Nightly bulk SAP extraction: separate Java + Spring Batch service writing to staging tables, narrowly amending ADR-0009; NestJS keeps incremental syncs and owns promotion into domain tables |
| [0018](0018-customer-representative-assignment-tenant-approval.md) | Customer Representative assignment to a Tenant now requires that Tenant's own Admin to approve first; identity stays a single global record, only the assignment mapping is gated |
| [0019](0019-automatic-card-payment-batch.md) | Automatic Card Payment batch: Spring Batch tier (restart-safety over throughput), fixed-retry SAP write-back notifying the Payer's AR Clerk (`payer_company_code.accounting_clerk_user_id`) on exhaustion, `card_payment`/`card_payment_attempt` tables; cross-currency threshold check via `currency_exchange_rate`, `card_payment_threshold_exceeded` tracking + daily Card Payment Threshold Alert job |
| [0020](0020-card-expiry-alert-and-stripe-sync.md) | Card Expiry Alert (NestJS, daily, 10-day proactive window, notifies AR Clerk(s)) paired with a Stripe webhook sync that keeps stored card expiry data current against Stripe's Network Tokens/Card Account Updater; establishes Stripe Connect (Standard account, `read_write` OAuth scope) plus its full connect/disconnect lifecycle |
| [0021](0021-parking-lot.md) | **Parking Lot** — living list of every open item across all ADRs/schema docs/build plan, updated in place as each is resolved (not a normal point-in-time decision record) |
| [0022](0022-sap-payment-webhook.md) | SAP Payment Webhook: inbound push of SAP-native payments only via a base + customer-specific SAP package pair (registered namespace, BTE-triggered, BAdI extension point for per-Tenant customization), bearer-token auth, routed via the Tenant's existing subdomain, logged to dedicated `sap_webhook_event`; retained as the preferred channel for critical data |
| [0023](0023-ar-reconciliation-batch.md) | AR Reconciliation batch: NestJS tier, SAP vs. AIARAP open AR compared per Payer/Company Code/currency, every account logged every run (not just variances), document-level drill-down via `ar_reconciliation_discrepancy`; `trigger_type` distinguishes scheduled full sweeps from webhook-triggered single-account checks (no merge needed — a scheduled run always wins on freshness by construction) |
| [0024](0024-ar-aging-trend-snapshots.md) | AR Aging trend snapshots: BI-style pre-computed fact tables (invoice-level + bucket rollup) distinguishing genuine collection from bucket-aging/new-invoice inflow, supports both scheduled and on-demand manual refresh |
| [0025](0025-stripe-payout-reconciliation.md) | Stripe payout reconciliation: AIARAP-origin inferred by matching (not tagged, since a Tenant's Connected Account can carry non-AIARAP charges), full payout composition surfaced, UTC-cutoff-aware rolling-window matching with a per-Tenant grace period auto-derived from Stripe's own payout schedule API, Tenant-editable bucketing of Stripe's raw transaction types, FX gain/loss separated from Stripe fees |
| [0026](0026-notification-channel.md) | Notification Channel: Email-only Phase 1 (SMS schema-ready, gated), template-driven and Tenant-editable, per-notification-type sender identity registration with provider-verification fallback |
| [0027](0027-salesforce-appexchange-integration.md) | Salesforce AppExchange Integration: AIARAP-built managed package, OAuth 2.0 auth (Named/External Credentials), broader-than-payments scope, third distinct integration boundary alongside Payment Provider and SAP Integration Adapter; same "richer payload for critical data" principle as the SAP webhook |

## Stack summary

| Layer | Choice | ADR |
|---|---|---|
| Cloud provider | AWS | [0005](0005-aws-as-default-cloud-provider.md) |
| Database | AWS RDS PostgreSQL (schema-per-tenant + `global` schema) | [0004](0004-schema-per-tenant-isolation.md), [0007](0007-rds-postgresql-over-aurora.md) |
| Identity | AWS Cognito, with per-Tenant SSO/IdP option | [0006](0006-identity-platform-aws-cognito-with-tenant-sso-option.md) |
| Backend | Node.js + TypeScript (NestJS) | [0009](0009-backend-nodejs-typescript.md) |
| Nightly bulk SAP extraction | Java + Spring Batch (staging tables, SQS handoff to NestJS promotion) | [0017](0017-sap-batch-extraction-java-spring-batch.md) |
| Frontend | React + TypeScript SPA (Vite) | [0008](0008-frontend-react-spa.md) |
| AR payments | Stripe, behind a Payment Provider interface | [0001](0001-payment-provider-abstraction.md) |
| AP payment execution | SAP native payment run (not built in-platform) | [0002](0002-ap-payment-execution-stays-in-sap.md) |
| Tenant custom fields | JSONB column + metadata table | [0003](0003-custom-fields-via-jsonb.md) |
| Security roles | Fixed roles, SAP-style Authorization Objects, Parent/Derived roles | [0010](0010-security-roles-authorization-objects.md) |
| User impersonation | "Login as," reason-gated for Payer/Vendor, 60-min max, full audit trail | [0011](0011-user-impersonation-audit-trail.md) |
| Role delegation | Self-service, per-Role, additive, time-boxed, approval-matrix-aware | [0012](0012-role-delegation.md) |
| Employee offboarding | Bulk reassignment by object type + open/closed, audit fields untouched | [0013](0013-employee-offboarding-reassignment.md) |
| Payer/Vendor onboarding/offboarding | Onboarding via existing Access Request flow; offboarding is permission-gated direct deactivation | [0014](0014-tenant-managed-payer-vendor-user-onboarding-offboarding.md) |
| Payer/Vendor Admin bootstrap | First Admin request routes to a permission-gated shared pool; Admin-access self-service closes once one exists | [0015](0015-payer-vendor-admin-bootstrap-via-access-request.md) |
| Payer/Vendor Admin user termination | Deactivate own regular Users (never a peer Admin); ends active Role Delegations | [0016](0016-payer-vendor-admin-user-termination.md) |
| Automatic Card Payment batch | Spring Batch tier; fixed-retry SAP write-back, then notify the Payer's AR Clerk; FX-aware threshold check + daily threshold-exceeded alert | [0019](0019-automatic-card-payment-batch.md) |
| Card Expiry Alert + Stripe sync | NestJS daily alert (10-day proactive window) + webhook-driven card-data refresh; Stripe Connect (one account per Tenant) for webhook routing | [0020](0020-card-expiry-alert-and-stripe-sync.md) |
| SAP Payment Webhook | Inbound push of SAP-native payments, routed via Tenant subdomain, `sap_webhook_secret_ref` auth | [0022](0022-sap-payment-webhook.md) |
| AR Reconciliation batch | NestJS; account-level (Payer/Company Code/currency) rollup + document-level drill-down | [0023](0023-ar-reconciliation-batch.md) |
| AR Aging trend snapshots | BI-style fact tables (invoice-level + bucket rollup); collected vs. aged vs. new classification; scheduled + manual refresh | [0024](0024-ar-aging-trend-snapshots.md) |
| Stripe payout reconciliation | AIARAP-origin inferred by matching; full payout composition surfaced; UTC-cutoff-aware rolling window | [0025](0025-stripe-payout-reconciliation.md) |
| Notification Channel | Email-only Phase 1, SMS schema-ready; template-driven, Tenant-editable | [0026](0026-notification-channel.md) |
| Salesforce AppExchange Integration | AIARAP-built managed package; OAuth 2.0; broader-than-payments scope | [0027](0027-salesforce-appexchange-integration.md) |
