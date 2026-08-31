# Phase 1 Table Structures

Working design doc for AIARAP's Postgres schema (schema-per-tenant per [ADR-0004](../adr/0004-schema-per-tenant-isolation.md)). Captures physical-design decisions that don't belong inside a specific product-decision ADR, plus the DDL built up domain-by-domain. Cross-cutting conventions decided first, then Tenancy/Identity → Security/Roles → Core AR/AP → Access/Onboarding → Batch/Integration.

## Cross-cutting conventions

- **Primary keys**: UUID v7 on every table. Not guessable/enumerable (Payer/Vendor Users hit these via the portal), no cross-schema/`global`-schema FK coordination needed, and v7's time-ordering avoids the index-bloat problem plain random UUID v4 has on insert.
- **Audit pattern — both**: every table gets standard audit columns (`created_at`, `created_by`, `updated_at`, `updated_by`, plus `status`/`is_active` for soft-delete per [ADR-0014](../adr/0014-tenant-managed-payer-vendor-user-onboarding-offboarding.md)'s "deactivation not deletion"). On top of that, a generic tenant-scoped `audit_log` table (entity_type, entity_id, action, actor_user_id, before/after JSONB, occurred_at) — AIARAP's CDHDR/CDPOS equivalent — captures field-level change history for compliance-sensitive actions (impersonation, offboarding, admin termination). Domain concepts with their own lifecycle (Role Delegation, Impersonation Session) still get dedicated tables; `audit_log` is for change tracking, not a replacement for tables the app queries directly.
- **Custom fields metadata**: one generic `custom_field_definition` table (tenant_id implicit via schema, `entity_type` discriminator, field_name, field_type, label, validation/options) across all extensible entities, rather than a metadata table per entity. Confirmed both by the reporting angle (one query/one view-generator vs. an ever-growing UNION as entities are added) and by precedent — Salesforce's own multi-tenant architecture uses one generic metadata-driven mechanism across every object, not bespoke per-object structures. Each extensible entity (Invoice, Bill, Payer, Vendor, ...) carries one `custom_fields JSONB` column per [ADR-0003](../adr/0003-custom-fields-via-jsonb.md).
- **Currency handling**: a `currency` reference table (`code` TEXT PRIMARY KEY — ISO 4217, e.g. `USD`/`JPY`/`COP`/`BHD` — `name`, `minor_unit` SMALLINT, `symbol`) is seeded identically into every `{tenant}` schema, consistent with the Finding 2 pattern for fixed reference data. Every money-bearing column pairs an amount with a `*_currency TEXT REFERENCES currency(code)` column, rather than assuming a platform-wide default currency. `minor_unit` (0 for JPY/COP/KRW, 2 for most currencies, 3 for BHD/KWD/OMR) drives decimal-precision validation, enforced at the **application layer** (a shared validation helper checking an amount's decimal places against its currency's `minor_unit`) rather than a DB trigger — a trigger would need a cross-table lookup on every write to every money column platform-wide (Invoice, Bill, Payment, RFQ Response lines, PO, ...), real maintenance overhead for what's a data-entry rule, not a structural integrity one.

## Open findings from the entity inventory — resolutions

1. **`Permission.authorization_object_id` nullability** — resolved, written into [ADR-0010](../adr/0010-security-roles-authorization-objects.md): nullable, `NULL` = an unscoped/meta-Permission (e.g. impersonation).
2. **Fixed reference data location** (Authorization Object, Permission, Parent Role) — resolved, written into ADR-0010: seeded per-`{tenant}` schema with fixed well-known UUIDs, not a shared `global` copy.
3. **Approval matrix approvers shape** — resolved: a child table `matrix_row_approver(row_id, user_id)`, one row per named approver (up to 3, enforced at the application layer rather than structurally), rather than 3 fixed columns. Applies to both the AP matrix (Bill line routing) and RFQ matrix (response header routing). Makes offboarding bulk-reassignment ([ADR-0013](../adr/0013-employee-offboarding-reassignment.md)) a single `UPDATE matrix_row_approver SET user_id = :new WHERE user_id = :old` per matrix, and "which rows list User X" a plain indexed join instead of a 3-column OR.
4. **Approval action record** — resolved: a separate insert-only log table per approval-bearing entity (`bill_line_approval`, `rfq_response_approval`) — `{line_id, matrix_row_id_matched, approver_user_id, decision, decided_at, comments}` — rather than approval columns directly on the line item. Makes `approved_by`/`decided_at` permanently immutable by construction (no special-case protection needed against ADR-0013's offboarding reassignment), and supports a rejected-then-resubmitted line getting a clean second approval cycle. The line item itself keeps a denormalized current-status column for fast queries.
5. **Contact scope re: Tenant Users** — resolved: Contact stays scoped to Payer/Vendor only, per its own stated definition (RFQ distribution, task assignment, email-interaction tracking with people outside the Tenant). Tenant Users are plain User rows with no Contact counterpart. CONTEXT.md's glossary line "every User is a Contact" is corrected to "every Payer/Vendor User is a Contact" — it was imprecise wording, not a real requirement to model internal staff as Contacts.
   - A related but distinct governance gap surfaced during this discussion — how much control a Tenant has over AIARAP staff (Customer Representative) access to its own environment — is resolved separately in [ADR-0018](../adr/0018-customer-representative-assignment-tenant-approval.md): Customer Representative identity stays a single global record (no per-tenant duplication), but *assignment* to a Tenant now requires that Tenant's own Admin to approve first.
6. **Bulk-reassignment-run history + bulk-upload batch tracking** (originally two separate findings) — resolved together as one generic table: `bulk_operation_run` (id, `operation_type` discriminator — e.g. `employee_offboarding_reassignment`, `payer_vendor_bulk_onboarding`, `matrix_excel_upload`, `payer_vendor_bulk_offboarding` — initiated_by, initiated_at, params JSONB, summary counts). Referenced via a `bulk_operation_run_id` on `audit_log` rows and on records created/touched during that run (e.g. Access Request, the reassignment target's owner/approver columns). Same "one mechanism, not N bespoke tables" pattern as `custom_field_definition` and `audit_log` — a future bulk operation type is a new discriminator value, not a new table.
7. **Vendor banking details cardinality** — resolved: a child table `vendor_bank_account(vendor_id, country, currency, routing_no, account_no, swift, ifsc, iban, is_primary)` rather than flat columns on Vendor, so a Vendor can hold separate accounts per currency/country. Mirrors SAP's own Vendor Master Bank Details (LFBK), already multi-row for the same reason.
8. **Tenant config location** (SAP/Salesforce connection, SSO/IdP settings) — resolved: a minimal `global.tenant_registry(id, subdomain, schema_name, status)` exists only because the app must resolve which schema to connect to before it can query anything Tenant-specific — the one genuinely bootstrap-necessary piece. Everything else (SAP/Salesforce connection config — endpoint + a Secrets Manager reference, never a raw credential in Postgres — SSO/IdP metadata, branding, minimum partial-payment amount) lives in a single-row `{tenant}.tenant_settings` table inside that Tenant's own schema, consistent with the per-tenant-storage philosophy already applied in Finding 2.

All 9 findings from the entity inventory are now resolved. Next: domain-by-domain DDL, starting with Tenancy & Identity.

## Domain: Tenancy & Identity

Naming/pattern notes that apply here and downstream:
- `app_user`, not `user` — avoids Postgres reserved-word-adjacent quoting friction.
- `id UUID PRIMARY KEY DEFAULT uuidv7()` — native in Postgres 18+; on an older major version, substitute the `pg_uuidv7` extension's function of the same name, no DDL change needed otherwise.
- `citext` extension used for case-insensitive email uniqueness.
- FK columns get an explicit index (Postgres does not auto-index them the way it does PKs) — shown per table below.
- Product and Sales Order (originally grouped under "Tenancy & Identity" in the raw inventory) are deferred to the Core AR/AP domain — they're catalog/transactional entities, not identity/tenancy ones.

### `global` schema

```sql
-- Minimal bootstrap registry. The app must resolve which {tenant} schema to
-- connect to before it can query anything Tenant-specific — this is the one
-- genuinely bootstrap-necessary piece (Finding 9). Everything else about a
-- Tenant lives in that Tenant's own tenant_settings row, EXCEPT
-- tenant_contact below — kept here deliberately (not in tenant_settings) so
-- AIARAP staff get a single cross-tenant "who do I call" directory query
-- without connecting into each Tenant's own schema.
CREATE TABLE global.tenant_registry (
    id                            UUID PRIMARY KEY DEFAULT uuidv7(),
    subdomain                     TEXT NOT NULL UNIQUE,
    schema_name                   TEXT NOT NULL UNIQUE,
    stripe_connected_account_id   TEXT UNIQUE,  -- ROUTING POINTER ONLY, not a Stripe "setting" — an opaque ID with no config/credentials attached, kept here purely so the webhook receiver can resolve the {tenant} schema before it can query anything tenant-specific (same bootstrap-necessity reasoning as subdomain/schema_name). The authoritative, app-facing copy — plus stripe_enabled and anything else Stripe-related — lives in tenant_settings (ADR-0020); the app layer keeps this pointer in sync with that copy at write time, same denormalization convention used elsewhere in this doc (e.g. card_payment_attempt.payer_id).
    status                        TEXT NOT NULL DEFAULT 'provisioning'
                                  CHECK (status IN ('provisioning', 'active', 'suspended', 'deprovisioned')),
    created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                    UUID,
    updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                    UUID
);
-- stripe_connected_account_id's plain UNIQUE (not a partial index) is
-- sufficient even though the column is nullable — Postgres UNIQUE
-- constraints treat multiple NULLs as non-conflicting.

-- Normalized in place of fixed primary/secondary columns — any number of
-- contacts per Tenant, not capped at 2. Mirrors the is_primary pattern
-- already used on vendor_bank_account.
CREATE TABLE global.tenant_contact (
    id                  UUID PRIMARY KEY DEFAULT uuidv7(),
    tenant_registry_id  UUID NOT NULL REFERENCES global.tenant_registry(id),
    name                TEXT NOT NULL,
    email               CITEXT,
    phone               TEXT,
    is_primary          BOOLEAN NOT NULL DEFAULT FALSE,
    status              TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by          UUID
);
CREATE INDEX ON tenant_contact (tenant_registry_id);
-- at most one ACTIVE primary per Tenant; an inactive old primary no longer
-- blocks promoting a new one (zero active primaries is allowed transiently)
CREATE UNIQUE INDEX ON tenant_contact (tenant_registry_id) WHERE is_primary AND status = 'active';

-- AIARAP's full internal staff directory — broader than Customer
-- Representative, covers any AIARAP employee whether or not they ever
-- touch a Tenant's environment. Single global identity, never duplicated
-- per Tenant.
CREATE TABLE global.aiarap_staff (
    id                     UUID PRIMARY KEY DEFAULT uuidv7(),
    name                   TEXT NOT NULL,
    email                  CITEXT NOT NULL UNIQUE,
    phone                  TEXT,
    office_address_line1   TEXT,
    office_address_line2   TEXT,
    office_city            TEXT,
    office_state_province  TEXT,
    office_postal_code     TEXT,
    office_country         TEXT,
    department             TEXT,  -- e.g. 'Customer Success', 'Engineering', 'Sales' — informational, not access-gating
    employment_status      TEXT NOT NULL DEFAULT 'active'
                           CHECK (employment_status IN ('active', 'terminated')),
    terminated_at          TIMESTAMPTZ,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by             UUID,
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by             UUID
);

-- Subtype/role-tag: marks which aiarap_staff rows are eligible for
-- Tenant-facing assignment (impersonation, ADR-0011). Not every staff
-- member needs one of these — table-per-subtype pattern, staff_id IS the
-- PK (strict 1:1), no separate surrogate key needed. Per-Tenant assignment
-- is gated separately (ADR-0018) via assigned_customer_representative below.
CREATE TABLE global.customer_representative (
    staff_id    UUID PRIMARY KEY REFERENCES global.aiarap_staff(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by  UUID
);
```

### `{tenant}` schema — deployed identically into every Tenant's schema

```sql
-- ISO 4217 reference data, seeded identically into every {tenant} schema
-- (same pattern as Finding 2's fixed reference data). minor_unit drives
-- decimal-precision validation at the application layer — see the
-- Currency handling cross-cutting convention above.
CREATE TABLE currency (
    code        TEXT PRIMARY KEY,   -- e.g. 'USD', 'JPY', 'COP', 'BHD'
    name        TEXT NOT NULL,
    minor_unit  SMALLINT NOT NULL DEFAULT 2,  -- 0 for JPY/COP/KRW/VND, 2 for most, 3 for BHD/KWD/OMR
    symbol      TEXT
);

-- SAP-sourced exchange rates (SAP TCURR-equivalent), extracted daily by the
-- Currency Exchange Rate Extraction job (docs/schema/0002-scheduled-jobs.md).
-- Reflects what the Tenant's SAP already has configured — AIARAP doesn't
-- compute/derive rates itself.
CREATE TABLE currency_exchange_rate (
    id             UUID PRIMARY KEY DEFAULT uuidv7(),
    rate_type      TEXT NOT NULL DEFAULT 'M',  -- SAP exchange rate type: M (standard), B (bank buying), G (bank selling), EURX, etc.
    from_currency  TEXT NOT NULL REFERENCES currency(code),
    to_currency    TEXT NOT NULL REFERENCES currency(code),
    rate_date      DATE NOT NULL,
    exchange_rate  NUMERIC(18,6) NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by     UUID,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by     UUID,
    UNIQUE (rate_type, from_currency, to_currency, rate_date)
);
CREATE INDEX ON currency_exchange_rate (from_currency, to_currency, rate_date);

-- Singleton settings row per Tenant. All Tenant-specific config lives here
-- (Finding 9) rather than centralized in `global`, consistent with
-- "a Tenant's schema is the complete picture of that Tenant."
CREATE TABLE tenant_settings (
    id                                   UUID PRIMARY KEY DEFAULT uuidv7(),
    singleton_guard                      BOOLEAN NOT NULL DEFAULT TRUE UNIQUE
                                          CHECK (singleton_guard),  -- forces exactly one row ever
    tenant_registry_id                   UUID NOT NULL REFERENCES global.tenant_registry(id),
    branding_logo_s3_key                 TEXT,  -- S3 object key, not a public URL; uploaded once, display URL (CDN/presigned) resolved at request time so a bucket/CDN change never breaks stored data
    branding_primary_color               TEXT,
    minimum_partial_payment_amount       NUMERIC(14,3) NOT NULL DEFAULT 0,  -- scale 3 to accommodate 3-decimal currencies (BHD/KWD/OMR); decimal-place validation against currency.minor_unit happens at the application layer
    minimum_partial_payment_currency     TEXT NOT NULL DEFAULT 'USD' REFERENCES currency(code),
    sap_system_of_record_enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    salesforce_system_of_record_enabled  BOOLEAN NOT NULL DEFAULT FALSE,
    sap_connection_endpoint              TEXT,
    sap_auth_type                        TEXT NOT NULL DEFAULT 'basic'
                                          CHECK (sap_auth_type IN ('basic', 'oauth2', 'certificate')),
    sap_basic_auth_username              TEXT,  -- non-secret; only meaningful when sap_auth_type = 'basic'
    sap_credential_secret_ref            TEXT,  -- AWS Secrets Manager ARN — password/client-secret/cert, never a raw credential here
    sap_credential_updated_at            TIMESTAMPTZ,  -- last time sap_credential_secret_ref's underlying secret was rotated
    sap_credential_validity_days         INTEGER,  -- how many days after sap_credential_updated_at the credential expires (per the Tenant's own SAP password policy); drives the Credential Expiry Alert job (0002-scheduled-jobs.md)
    sap_oauth_token_secret_ref           TEXT,  -- AWS Secrets Manager ARN holding the current cached bearer token; only meaningful when sap_auth_type = 'oauth2'
    sap_oauth_token_expires_at           TIMESTAMPTZ,  -- non-sensitive; lets the refresh job (and callers) know staleness without reading the secret
    salesforce_connection_endpoint       TEXT,
    salesforce_auth_type                 TEXT NOT NULL DEFAULT 'oauth2'
                                          CHECK (salesforce_auth_type IN ('basic', 'oauth2', 'certificate')),  -- Salesforce's REST/Bulk APIs are OAuth2-only in practice; 'basic'/'certificate' kept for symmetry, not expected to be used
    salesforce_basic_auth_username       TEXT,  -- non-secret; only meaningful when salesforce_auth_type = 'basic'
    salesforce_credential_secret_ref     TEXT,  -- AWS Secrets Manager ARN — password/client-secret/cert, never a raw credential here
    salesforce_credential_updated_at     TIMESTAMPTZ,  -- last time salesforce_credential_secret_ref's underlying secret was rotated
    salesforce_credential_validity_days  INTEGER,  -- how many days after salesforce_credential_updated_at the credential expires; drives the Credential Expiry Alert job (0002-scheduled-jobs.md)
    salesforce_oauth_token_secret_ref    TEXT,  -- AWS Secrets Manager ARN holding the current cached bearer token; only meaningful when salesforce_auth_type = 'oauth2'
    salesforce_oauth_token_expires_at    TIMESTAMPTZ,  -- non-sensitive; lets the refresh job (and callers) know staleness without reading the secret
    salesforce_app_enabled               BOOLEAN NOT NULL DEFAULT FALSE,  -- distinct from salesforce_system_of_record_enabled above: this gates the AIARAP AppExchange package calling INTO AIARAP (ADR-0027), the reverse direction from every other salesforce_* field on this table, which is AIARAP calling OUT to extract data
    salesforce_app_client_id             TEXT,  -- OAuth 2.0 client ID AIARAP issued to this Tenant's installed package instance; non-secret
    salesforce_app_client_secret_ref     TEXT,  -- AWS Secrets Manager ARN — the matching client secret, never a raw credential here
    sso_enabled                          BOOLEAN NOT NULL DEFAULT FALSE,
    sso_provider_type                    TEXT CHECK (sso_provider_type IN ('saml', 'oidc')),
    sso_metadata_secret_ref              TEXT,
    stripe_enabled                       BOOLEAN NOT NULL DEFAULT FALSE,  -- not every Tenant uses Stripe/card payments (ADR-0020); gates the Automatic Card Payment batch, Card Expiry Alert, and webhook processing for this Tenant
    stripe_connected_account_id          TEXT,  -- authoritative, app-facing copy of the Stripe Connect account ID (ADR-0020); global.tenant_registry keeps a routing-only pointer to the same value, kept in sync at write time
    stripe_disconnected_at               TIMESTAMPTZ,  -- set when a Tenant disconnects Stripe (ADR-0020); stripe_connected_account_id is deliberately NOT cleared on disconnect — kept as a historical record, same "deactivation not deletion" convention used elsewhere, and both routing-pointer copies stay intact so any late in-flight webhook for a pre-disconnect charge still resolves to the right Tenant rather than being orphaned
    stripe_payout_interval                TEXT CHECK (stripe_payout_interval IN ('daily', 'weekly', 'monthly', 'manual')),  -- synced from Stripe's Account API (settings.payouts.schedule), not manually configured — refreshed by the Stripe Payout Reconciliation job (ADR-0025) each run so a Tenant changing their payout schedule directly in Stripe stays reflected here automatically
    stripe_payout_delay_days              INTEGER,  -- synced alongside stripe_payout_interval; drives the reconciliation grace-period window (parking lot item 23, resolved) — NULL until first synced, in which case the job falls back to the 5-day platform default
    sap_webhook_secret_ref               TEXT,  -- AWS Secrets Manager ARN — shared secret configured on the Tenant's SAP outbound side (e.g. an HTTP destination or CPI/PI channel), used to authenticate inbound calls to the SAP Payment Webhook (ADR-0022). Routing itself doesn't need a new global field — the webhook URL AIARAP issues already embeds this Tenant's subdomain (global.tenant_registry.subdomain), unlike Stripe's opaque connected-account-id routing
    card_auto_pay_max_failed_attempts    INTEGER NOT NULL DEFAULT 3,  -- Tenant-configurable threshold: consecutive Automatic Card Payment batch failures before a card is excluded from future auto-pay runs (payer_payment_card.auto_pay_blocked, ADR-0019)
    sms_notifications_enabled            BOOLEAN NOT NULL DEFAULT FALSE,  -- gates SMS as a Notification Channel once built; Email is the only implementation in Phase 1
    created_at                           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                           UUID,
    updated_at                           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                           UUID
);
CREATE INDEX ON tenant_settings (tenant_registry_id);
```

**OAuth token refresh jobs**: see `0002-scheduled-jobs.md` for the SAP and Salesforce refresh job definitions. In short: `*_oauth_token_secret_ref` is rotated in place (same ARN, new value) 2 minutes ahead of `*_oauth_token_expires_at`; programs fetch the cached token from Secrets Manager via that stable ref rather than each fetching/refreshing their own.

**Security**: the token itself follows the same rule as every other credential on this table — never a raw value in Postgres, only a Secrets Manager reference. Only `*_oauth_token_expires_at` (a plain timestamp, not sensitive) lives here directly, which is what lets the refresh job — and any caller wanting a cheap staleness check — avoid a Secrets Manager round-trip just to know *whether* a refresh is due.

```sql
-- Tenant-registered sender DOMAIN identities — the only thing actually
-- collected from the Tenant is the domain itself (or the desired sender
-- address, from which the domain is derived); everything else here is
-- GENERATED by the email provider (AWS SES) and handed back to the Tenant
-- to add to their own DNS, not collected from them. Domain-level, not
-- per-address, because that's how SES's DKIM verification actually works:
-- once a domain is verified, ANY address at it (invoice@, ar@, ...) can be
-- used without separately re-verifying each one — a single verified
-- identity naturally covers every notification_type that wants an address
-- at that domain, matching the "register a sender by notification"
-- reuse goal from ADR-0026 without per-address re-verification overhead.
-- verification_status is the roll-up of every required DNS record below
-- (notification_sender_dns_record) all verifying — never assumed true at
-- insert time.
CREATE TABLE notification_sender_identity (
    id                          UUID PRIMARY KEY DEFAULT uuidv7(),
    domain                      CITEXT NOT NULL UNIQUE,  -- e.g. 'tenant.com' — the ONE piece of information actually collected from the Tenant
    verification_status         TEXT NOT NULL DEFAULT 'pending'
                                CHECK (verification_status IN ('pending', 'verified', 'failed')),
    provider_verification_ref   TEXT,  -- e.g. AWS SES Identity ARN for the domain
    verified_at                 TIMESTAMPTZ,
    status                      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                  UUID,
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                  UUID
);

-- The DNS records the Tenant must add to their own DNS host — GENERATED
-- by SES (e.g. 3 DKIM CNAME tokens per domain) when
-- notification_sender_identity is created, not entered by the Tenant.
-- SES verifies each record independently by periodically querying DNS;
-- the identity's overall verification_status only flips to 'verified'
-- once every required record here does. An optional SPF TXT record is
-- also generated/recommended for deliverability, tracked the same way.
CREATE TABLE notification_sender_dns_record (
    id                    UUID PRIMARY KEY DEFAULT uuidv7(),
    sender_identity_id    UUID NOT NULL REFERENCES notification_sender_identity(id),
    record_purpose        TEXT NOT NULL CHECK (record_purpose IN ('dkim', 'spf')),
    record_type           TEXT NOT NULL CHECK (record_type IN ('CNAME', 'TXT')),
    record_name           TEXT NOT NULL,  -- the DNS host/name the Tenant must create, e.g. 'abc123._domainkey.tenant.com'
    record_value          TEXT NOT NULL,  -- the value/target, e.g. 'abc123.dkim.amazonses.com'
    verification_status   TEXT NOT NULL DEFAULT 'pending'
                          CHECK (verification_status IN ('pending', 'verified', 'failed')),
    verified_at           TIMESTAMPTZ,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            UUID,
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by            UUID
);
CREATE INDEX ON notification_sender_dns_record (sender_identity_id);

-- The Notification Channel abstraction (ADR-0026) — Email is the only
-- Phase 1 implementation, SMS is schema-ready (gated by
-- tenant_settings.sms_notifications_enabled) but has no working provider
-- integration yet. Template-driven and Tenant-editable: seeded with
-- default content per (notification_type, channel) at provisioning, same
-- "seeded per-tenant schema, then divergeable" treatment as Finding 2's
-- fixed reference data — unlike currency (globally fixed, never diverges
-- per Tenant), a Tenant may edit their own copy's wording/branding.
-- sender_identity_id NULL = send from the AIARAP-owned default address;
-- set = this notification_type sends from sender_email at that Tenant-
-- registered domain, PROVIDED the identity's verification_status =
-- 'verified' at send time — the app must fall back to the AIARAP default
-- otherwise (an unverified/failed identity would simply be rejected by
-- the email provider, not silently degrade). sender_email lives here, not
-- on notification_sender_identity, since the identity is domain-level —
-- one verified domain can back several different addresses across
-- different notification_types (invoice@tenant.com for one, ar@tenant.com
-- for another), matching the "register a sender by notification" ask
-- without re-verifying per address.
CREATE TABLE notification_template (
    id                 UUID PRIMARY KEY DEFAULT uuidv7(),
    notification_type  TEXT NOT NULL,  -- discriminator: 'credential_expiry_alert', 'card_expiry_alert', 'ar_write_back_failure', 'guest_lookup_repeated_failure', etc. — one mechanism, not a table per alert type
    channel            TEXT NOT NULL DEFAULT 'email' CHECK (channel IN ('email', 'sms')),
    sender_identity_id UUID REFERENCES notification_sender_identity(id),
    sender_email       CITEXT,  -- NULL alongside sender_identity_id (AIARAP default); when set, its domain must match sender_identity_id's domain — enforced at the application layer, not a DB constraint (same convention as other cross-column consistency rules in this doc)
    sender_name        TEXT,  -- display name, e.g. 'Acme Corp AR Team'
    subject_template   TEXT,  -- NULL for sms (no subject concept); supports variable substitution, e.g. {{payer_name}}, {{invoice_number}}
    body_template      TEXT NOT NULL,
    status             TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         UUID,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by         UUID,
    UNIQUE (notification_type, channel)
);

-- Insert-only send log — one row per notification actually dispatched.
-- template_id is NOT NULL: every notification_type/channel combination
-- must have a configured template before anything can be sent through it,
-- rather than silently falling back to ad-hoc content. subject/body store
-- the RENDERED result at send time (not just a template reference) so
-- history reflects what a recipient actually received even if the
-- template is edited afterward. related_entity_type/related_entity_id are
-- a polymorphic reference, same pattern as audit_log, letting a
-- notification point back at whatever triggered it (a card_payment, an
-- ar_reconciliation_account, etc.) without a FK per possible source.
CREATE TABLE notification (
    id                   UUID PRIMARY KEY DEFAULT uuidv7(),
    recipient_user_id    UUID NOT NULL REFERENCES app_user(id),
    channel              TEXT NOT NULL DEFAULT 'email' CHECK (channel IN ('email', 'sms')),
    notification_type    TEXT NOT NULL,
    template_id          UUID NOT NULL REFERENCES notification_template(id),
    sender_identity_id   UUID REFERENCES notification_sender_identity(id),  -- the identity ACTUALLY used — NULL means the AIARAP default was used, whether because the template specified no identity or because a specified one wasn't 'verified' at send time (the fallback rule on notification_template.sender_identity_id)
    sender_email         TEXT NOT NULL,  -- snapshot of the From address actually used, same "store what was actually sent" reasoning as subject/body — protects history if the identity is edited or removed later
    subject              TEXT,
    body                 TEXT NOT NULL,
    related_entity_type  TEXT,
    related_entity_id    UUID,
    status               TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed')),
    sent_at              TIMESTAMPTZ,
    failure_reason       TEXT,
    retry_count          INTEGER NOT NULL DEFAULT 0,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           UUID,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by           UUID
);
CREATE INDEX ON notification (recipient_user_id);
CREATE INDEX ON notification (notification_type);
CREATE INDEX ON notification (status);  -- drives any retry sweep of 'failed'/'pending' rows
CREATE INDEX ON notification (related_entity_type, related_entity_id);
```

```sql
-- Gates Customer Rep assignment behind Tenant Admin approval (ADR-0018).
CREATE TABLE customer_representative_assignment_request (
    id               UUID PRIMARY KEY DEFAULT uuidv7(),
    customer_rep_id  UUID NOT NULL REFERENCES global.customer_representative(staff_id),
    status           TEXT NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'approved', 'denied')),
    requested_by     UUID NOT NULL REFERENCES global.aiarap_staff(id),  -- any AIARAP staff member, not necessarily a Customer Representative themselves
    decided_by       UUID REFERENCES app_user(id),  -- the Tenant Admin who acted
    decided_at       TIMESTAMPTZ,
    denial_reason    TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       UUID,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by       UUID
);
CREATE INDEX ON customer_representative_assignment_request (customer_rep_id);
CREATE INDEX ON customer_representative_assignment_request (status);

-- Only rows here (approved requests) let a rep initiate an impersonation
-- session in this Tenant. Soft-revocable with history, not hard-deleted —
-- consistent with "deactivation not deletion" elsewhere in the platform.
CREATE TABLE assigned_customer_representative (
    id                     UUID PRIMARY KEY DEFAULT uuidv7(),
    customer_rep_id        UUID NOT NULL REFERENCES global.customer_representative(staff_id),
    assignment_request_id  UUID REFERENCES customer_representative_assignment_request(id),  -- traces this row back to the approved request that authorized it
    is_active              BOOLEAN NOT NULL DEFAULT TRUE,
    valid_upto             TIMESTAMPTZ,  -- NULL = indefinite; assignment expires (not just is_active := false) once past this
    deactivated_by         UUID REFERENCES app_user(id),  -- the Tenant Admin who manually revoked this assignment; is_active no longer flips automatically for expiry/termination (see live-check convention above), so a false here is always a deliberate action
    deactivated_at         TIMESTAMPTZ,
    deactivation_reason    TEXT,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by             UUID,
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by             UUID
);
CREATE INDEX ON assigned_customer_representative (customer_rep_id);
-- at most one *active* assignment per rep at a time; reactivation inserts a new row
CREATE UNIQUE INDEX ON assigned_customer_representative (customer_rep_id) WHERE is_active;
```

**Live-check convention (supersedes an earlier scheduled-job design — see `0002-scheduled-jobs.md`)**: "effectively active" depends on three conditions, all evaluated live rather than cached via a scheduled write:

```
is_active
  AND (valid_upto IS NULL OR valid_upto > now())
  AND global.aiarap_staff.employment_status = 'active'   -- cross-schema join via global.customer_representative
```

The partial unique index above only guards against two *flagged*-active rows for the same rep — it doesn't know about `valid_upto` elapsing or the underlying staff member being terminated at AIARAP. Rather than a scheduled job denormalizing either fact into `is_active` (which was the original design here, and which for termination would have meant fanning out writes across every `{tenant}` schema — a real cross-schema-boundary problem, since `aiarap_staff` lives in `global`), every place that checks assignment validity evaluates the full expression live: impersonation session start, and — to close the mid-session gap where a rep is terminated while already impersonating — every impersonation action, reusing ADR-0011's existing per-action middleware. On termination, the app also disables the staff member's Cognito identity (`AdminDisableUser` + `AdminUserGlobalSignOut`) as defense-in-depth, but that's not the enforcement mechanism — the live DB check is.

```sql
CREATE TABLE payer (
    id                      UUID PRIMARY KEY DEFAULT uuidv7(),
    sap_customer_id         TEXT,
    salesforce_customer_id  TEXT,
    name                    TEXT NOT NULL,
    tax_id                  TEXT,
    currency                TEXT REFERENCES currency(code),  -- default/expected billing currency
    address_line1           TEXT,
    address_line2           TEXT,
    city                    TEXT,
    state_province          TEXT,
    postal_code             TEXT,
    country                 TEXT,
    custom_fields           JSONB NOT NULL DEFAULT '{}'::jsonb,
    status                  TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag           BOOLEAN NOT NULL DEFAULT FALSE,  -- SAP LOEVM-equivalent: marked for archival/removal, distinct from status — the record still exists and is queryable until an actual archiving run processes it
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              UUID,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by              UUID,
    CONSTRAINT payer_source_id_present
        CHECK (sap_customer_id IS NOT NULL OR salesforce_customer_id IS NOT NULL)
);
CREATE UNIQUE INDEX ON payer (sap_customer_id) WHERE sap_customer_id IS NOT NULL;
CREATE UNIQUE INDEX ON payer (salesforce_customer_id) WHERE salesforce_customer_id IS NOT NULL;

-- SAP KNVH-equivalent (Customer Hierarchy): time-sliced and sales-area-scoped
-- — a Payer can roll up to a different parent depending on Sales Org/
-- Distribution Channel/Division, and a reassignment closes one validity
-- period and opens a new one rather than overwriting history. Replaces an
-- earlier flat payer.parent_payer_id column (removed).
CREATE TABLE payer_hierarchy (
    id                    UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id              UUID NOT NULL REFERENCES payer(id),   -- the lower-level (child) node
    parent_payer_id       UUID NOT NULL REFERENCES payer(id),   -- the higher-level node
    sales_org             TEXT NOT NULL,
    distribution_channel  TEXT NOT NULL,
    division              TEXT NOT NULL,
    valid_from            DATE NOT NULL,
    valid_to              DATE,  -- NULL = open-ended / currently valid
    deletion_flag         BOOLEAN NOT NULL DEFAULT FALSE,  -- SAP LOEVM-equivalent
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            UUID,
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by            UUID,
    CONSTRAINT payer_hierarchy_not_self_parent CHECK (payer_id <> parent_payer_id)
);
CREATE INDEX ON payer_hierarchy (payer_id);
CREATE INDEX ON payer_hierarchy (parent_payer_id);
-- Non-overlapping valid_from/valid_to per (payer_id, sales_org,
-- distribution_channel, division) is an application-layer rule, not a DB
-- constraint — consistent with the Currency handling cross-cutting
-- convention (decimal-place validation is app-layer too): reassignment
-- must close the prior period (set valid_to) before opening a new one.

-- Stores a tokenized payment card reference — never a raw PAN/CVV, per the
-- spec's SAQ A PCI scope (client-side tokenization via Stripe Elements/
-- Checkout) — abstracted generically per ADR-0001's Payment Provider
-- interface rather than Stripe-specific column names. Owned by a Payer; a
-- card registered by a parent Payer can optionally be shared for use by its
-- children (resolved via payer_hierarchy) through allow_child_use.
CREATE TABLE payer_payment_card (
    id                           UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id                     UUID NOT NULL REFERENCES payer(id),  -- owning Payer
    provider                     TEXT NOT NULL DEFAULT 'stripe',      -- generic per ADR-0001; not assumed to stay Stripe-only
    provider_customer_ref        TEXT,           -- e.g. Stripe Customer ID (cus_xxx)
    provider_payment_method_ref  TEXT NOT NULL,  -- e.g. Stripe PaymentMethod ID (pm_xxx) — the actual token
    card_brand                   TEXT,           -- 'visa', 'mastercard', ... — safe, non-sensitive metadata returned by the provider
    card_last4                   TEXT,
    card_exp_month               SMALLINT,
    card_exp_year                SMALLINT,
    is_primary                   BOOLEAN NOT NULL DEFAULT FALSE,
    allow_child_use              BOOLEAN NOT NULL DEFAULT FALSE,  -- can a child Payer (per payer_hierarchy, any sales area, currently valid) charge this card?
    consecutive_failed_attempts  INTEGER NOT NULL DEFAULT 0,  -- reset to 0 on any successful card_payment_attempt; incremented on each failed one, drives auto_pay_blocked below (ADR-0019)
    auto_pay_blocked             BOOLEAN NOT NULL DEFAULT FALSE,  -- set once consecutive_failed_attempts reaches tenant_settings.card_auto_pay_max_failed_attempts — excludes this card from the Automatic Card Payment batch ONLY; distinct from status, since the Payer can still see/retry it manually in the portal
    auto_pay_blocked_at          TIMESTAMPTZ,
    status                       TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag                BOOLEAN NOT NULL DEFAULT FALSE,
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                   UUID,
    updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                   UUID,
    UNIQUE (provider, provider_payment_method_ref)
);
CREATE INDEX ON payer_payment_card (payer_id);
-- at most one active primary per Payer; same convention as tenant_contact/contact
CREATE UNIQUE INDEX ON payer_payment_card (payer_id) WHERE is_primary AND status = 'active';

-- Per-card policy: which Invoice types a specific stored card may be used
-- for, within what Company Code, within what time window, and up to what
-- amount per charge. invoice_type now references the invoice_type table
-- (Core AR/AP domain, further down this file — extracted per Tenant from
-- their SAP billing-type customizing, TVFK-equivalent) rather than staying
-- plain TEXT. company_code likewise gets a real composite FK —
-- payer_company_code is the local source of truth for which company codes
-- exist for this Payer (not mirrored SAP data with nothing local to check
-- against), preventing a policy from ever pointing at a company code the
-- Payer doesn't actually have on file. payer_id is denormalized alongside
-- payer_payment_card_id for query convenience — the app layer keeps it
-- consistent with the card's own payer_id at write time, same as the
-- overlap rule below.
CREATE TABLE payer_card_payment_policy (
    id                     UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id               UUID NOT NULL REFERENCES payer(id),
    payer_payment_card_id  UUID NOT NULL REFERENCES payer_payment_card(id),
    company_code           TEXT NOT NULL,
    invoice_type           TEXT NOT NULL REFERENCES invoice_type(code),
    valid_from             DATE NOT NULL,
    valid_to               DATE,  -- NULL = open-ended
    max_amount_per_charge  NUMERIC(18,2) NOT NULL,
    max_amount_currency    TEXT NOT NULL REFERENCES currency(code),
    status                 TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag          BOOLEAN NOT NULL DEFAULT FALSE,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by             UUID,
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by             UUID,
    CONSTRAINT payer_card_payment_policy_company_code_fk
        FOREIGN KEY (payer_id, company_code)
        REFERENCES payer_company_code (payer_id, company_code),
    UNIQUE (payer_payment_card_id, company_code, invoice_type, valid_from)
);
CREATE INDEX ON payer_card_payment_policy (payer_id);
CREATE INDEX ON payer_card_payment_policy (payer_payment_card_id);
CREATE INDEX ON payer_card_payment_policy (payer_id, company_code);
-- Non-overlapping valid_from/valid_to per (payer_payment_card_id,
-- company_code, invoice_type) is an application-layer rule, not a DB constraint — same
-- convention as payer_hierarchy above.

-- Tracks Invoices currently ineligible for the Automatic Card Payment
-- batch because their amount — converted into the matching policy's
-- max_amount_currency via today's rate in currency_exchange_rate, when
-- currencies differ (parking lot item 1, resolved) — exceeds
-- max_amount_per_charge, or because no exchange rate was available to
-- even attempt that conversion. Upserted daily by the batch, not an
-- insert-only log: the same Invoice staying over-threshold across
-- multiple days updates in place (last_checked_at, and its amounts if
-- open_amount changed) rather than accumulating duplicate rows.
-- resolved_at is set once the batch no longer detects the condition
-- (paid, policy raised, exchange rate now available) — kept, not
-- deleted, as an audit trail of past exceptions. Drives the Card Payment
-- Threshold Alert job (0002-scheduled-jobs.md), which notifies the
-- affected AR Clerk(s) daily for as long as resolved_at stays NULL.
CREATE TABLE card_payment_threshold_exceeded (
    id                     UUID PRIMARY KEY DEFAULT uuidv7(),
    invoice_id             UUID NOT NULL REFERENCES invoice(id),
    payer_payment_card_id  UUID NOT NULL REFERENCES payer_payment_card(id),
    policy_id              UUID NOT NULL REFERENCES payer_card_payment_policy(id),
    skip_reason            TEXT NOT NULL
                           CHECK (skip_reason IN ('threshold_exceeded', 'no_exchange_rate_available')),
    invoice_amount         NUMERIC(18,2) NOT NULL,  -- the Invoice's own open_amount, in its own currency
    invoice_currency       TEXT NOT NULL REFERENCES currency(code),
    converted_amount       NUMERIC(18,2),  -- invoice_amount converted into max_amount_currency; NULL when currencies already matched, or when skip_reason = 'no_exchange_rate_available'
    exchange_rate_used     NUMERIC(18,6),  -- the currency_exchange_rate.exchange_rate applied; NULL under the same conditions as converted_amount
    max_amount_per_charge  NUMERIC(18,2) NOT NULL,  -- the policy's threshold, snapshotted (the policy itself could change later)
    max_amount_currency    TEXT NOT NULL REFERENCES currency(code),
    first_detected_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_checked_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at            TIMESTAMPTZ,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by             UUID,
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by             UUID,
    UNIQUE (invoice_id, policy_id)
);
CREATE INDEX ON card_payment_threshold_exceeded (payer_payment_card_id);
CREATE INDEX ON card_payment_threshold_exceeded (policy_id);
-- drives both the batch's re-evaluation sweep and the daily notification query
CREATE INDEX ON card_payment_threshold_exceeded (invoice_id) WHERE resolved_at IS NULL;

-- Supports the Automatic Card Payment batch job (0002-scheduled-jobs.md).
-- invoice_id now has a real FK — Invoice was designed later in this same
-- session, in the Core AR/AP domain further down this file (parking lot
-- item 8, resolved). Named generically (card_payment, not
-- payer_card_auto_payment) because Core AR/AP's manual portal card payment
-- flow is expected to write to the same table — initiated_via
-- distinguishes the source rather than forking into two tables for what's
-- the same underlying fact (a card was charged successfully for an
-- Invoice).
CREATE TABLE card_payment (
    id                       UUID PRIMARY KEY DEFAULT uuidv7(),
    invoice_id               UUID NOT NULL REFERENCES invoice(id),
    payer_id                 UUID NOT NULL REFERENCES payer(id),
    payer_payment_card_id    UUID NOT NULL REFERENCES payer_payment_card(id),
    initiated_via            TEXT NOT NULL DEFAULT 'auto_batch'
                             CHECK (initiated_via IN ('auto_batch', 'manual_portal')),
    amount                   NUMERIC(18,2) NOT NULL,
    currency                 TEXT NOT NULL REFERENCES currency(code),
    provider                 TEXT NOT NULL DEFAULT 'stripe',
    provider_charge_ref      TEXT NOT NULL,  -- e.g. Stripe PaymentIntent/Charge ID
    provider_fee_amount      NUMERIC(18,2),  -- gross/fee/net breakdown per spec story 11 (Credit Card reconciliation)
    charged_at               TIMESTAMPTZ NOT NULL,
    sap_posting_status       TEXT NOT NULL DEFAULT 'pending'
                             CHECK (sap_posting_status IN ('pending', 'posted', 'failed')),
    sap_posting_reference    TEXT,     -- SAP clearing document number once posted
    sap_posting_attempts     INTEGER NOT NULL DEFAULT 0,
    sap_posting_last_error   TEXT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by               UUID,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by               UUID,
    UNIQUE (provider, provider_charge_ref)
);
CREATE INDEX ON card_payment (invoice_id);
CREATE INDEX ON card_payment (payer_id);
CREATE INDEX ON card_payment (payer_payment_card_id);
CREATE INDEX ON card_payment (sap_posting_status);  -- drives the SAP write-back retry sweep

-- Insert-only log of every charge attempt against the Payment Provider,
-- success or failure — same "log for compliance, dedicated table for what
-- the app queries directly" split as bill_line_approval/rfq_response_approval
-- (Finding 4). card_payment_id is set only when outcome = 'succeeded'.
CREATE TABLE card_payment_attempt (
    id                      UUID PRIMARY KEY DEFAULT uuidv7(),
    invoice_id              UUID NOT NULL REFERENCES invoice(id),
    payer_id                UUID NOT NULL REFERENCES payer(id),
    payer_payment_card_id   UUID NOT NULL REFERENCES payer_payment_card(id),
    policy_id               UUID REFERENCES payer_card_payment_policy(id),  -- which policy authorized this attempt; NULL for manual_portal payments, which don't go through the policy check
    initiated_via           TEXT NOT NULL DEFAULT 'auto_batch'
                            CHECK (initiated_via IN ('auto_batch', 'manual_portal')),
    attempted_amount        NUMERIC(18,2) NOT NULL,
    attempted_currency      TEXT NOT NULL REFERENCES currency(code),
    provider                TEXT NOT NULL DEFAULT 'stripe',
    provider_request_ref    TEXT,  -- e.g. Stripe PaymentIntent ID, present even on failure
    outcome                 TEXT NOT NULL CHECK (outcome IN ('succeeded', 'failed')),
    failure_code            TEXT,
    failure_message         TEXT,
    card_payment_id         UUID REFERENCES card_payment(id),  -- set when outcome = 'succeeded'
    attempted_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              UUID
);
CREATE INDEX ON card_payment_attempt (invoice_id);
CREATE INDEX ON card_payment_attempt (payer_id);
CREATE INDEX ON card_payment_attempt (payer_payment_card_id);

-- Log of every incoming Payment Provider webhook event (ADR-0020), named
-- generically per ADR-0001 rather than Stripe-specific — not scoped to
-- card-data updates only, so any future webhook-driven event (e.g. charge
-- confirmation) reuses the same table rather than forking a new one.
-- By the time an event reaches this table, the webhook receiver has
-- already resolved which {tenant} schema to write into via
-- global.tenant_registry.stripe_connected_account_id — this table only
-- exists inside that resolved schema. UNIQUE(provider, provider_event_id)
-- gives idempotency: Stripe can (and does) redeliver the same event more
-- than once, and a redelivery within the same Tenant must not reprocess.
CREATE TABLE payment_provider_webhook_event (
    id                  UUID PRIMARY KEY DEFAULT uuidv7(),
    provider            TEXT NOT NULL DEFAULT 'stripe',
    provider_event_id   TEXT NOT NULL,  -- e.g. Stripe Event ID (evt_xxx)
    event_type          TEXT NOT NULL,  -- e.g. Stripe's payment_method.updated (exact event name TBD, see ADR-0020 open item)
    payload             JSONB NOT NULL,
    status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'processed', 'failed', 'ignored')),
    processed_at        TIMESTAMPTZ,
    processing_error    TEXT,
    received_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by          UUID,
    UNIQUE (provider, provider_event_id)
);
CREATE INDEX ON payment_provider_webhook_event (status);  -- drives any reprocessing sweep of 'failed'/'pending' rows

-- SAP KNVV-equivalent (Sales Area Data), kept minimal: a Payer can have
-- different sales terms per Sales Org + Distribution Channel + Division.
CREATE TABLE payer_sales_area (
    id                          UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id                    UUID NOT NULL REFERENCES payer(id),
    sales_org                   TEXT NOT NULL,
    distribution_channel        TEXT NOT NULL,
    division                    TEXT NOT NULL,
    currency                    TEXT REFERENCES currency(code),
    payment_terms               TEXT,
    price_group                 TEXT,
    incoterms_1                 TEXT,  -- Incoterms classification, e.g. 'FOB', 'CIF'
    incoterms_2                 TEXT,  -- named place/location qualifying incoterms_1, e.g. 'Mumbai Port'
    customer_group              TEXT,
    shipping_plant              TEXT,  -- delivering plant
    shipping_conditions         TEXT,
    order_combination_allowed   BOOLEAN NOT NULL DEFAULT FALSE,  -- whether multiple orders can be combined into one delivery
    billing_block               BOOLEAN NOT NULL DEFAULT FALSE,  -- SAP KNVV-FAKSD-equivalent: blocks invoicing for this Sales Org/Distribution Channel/Division only, distinct from payer_company_code.credit_hold
    billing_block_reason        TEXT,
    deletion_flag               BOOLEAN NOT NULL DEFAULT FALSE,  -- SAP LOEVM-equivalent, scoped to this sales area only
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                  UUID,
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                  UUID,
    UNIQUE (payer_id, sales_org, distribution_channel, division)
);
CREATE INDEX ON payer_sales_area (payer_id);

-- SAP KNB1-equivalent (Company Code Data), kept minimal: a Payer can have
-- different accounting terms per Company Code.
CREATE TABLE payer_company_code (
    id                         UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id                   UUID NOT NULL REFERENCES payer(id),
    company_code               TEXT NOT NULL,
    reconciliation_gl_account  TEXT,
    payment_terms              TEXT,
    accounting_clerk_user_id   UUID REFERENCES app_user(id),  -- SAP KNB1-BUSAB-equivalent, but a real AIARAP account (not a code string) so it's an actual notification target — resolves "AR Clerk" for ADR-0019's SAP write-back failure alert, avoids inundating a single Tenant Admin
    dunning_clerk              TEXT,
    statement_frequency        TEXT,  -- e.g. 'monthly', 'weekly', 'on-demand'
    credit_limit               NUMERIC(18,2),  -- SAP FD32/KNKK-equivalent, scoped to this company code
    credit_hold                BOOLEAN NOT NULL DEFAULT FALSE,  -- AR-side counterpart to vendor_company_code.payment_block
    credit_hold_reason         TEXT,
    deletion_flag              BOOLEAN NOT NULL DEFAULT FALSE,  -- SAP LOEVM-equivalent, scoped to this company code only
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                 UUID,
    updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                 UUID,
    UNIQUE (payer_id, company_code)
);
CREATE INDEX ON payer_company_code (payer_id);
CREATE INDEX ON payer_company_code (accounting_clerk_user_id);

-- SAP LFA1-equivalent (General Data). Company-code-specific and
-- purchasing-org-specific data are split out below (vendor_company_code /
-- vendor_purchasing_org), mirroring the payer/payer_company_code/
-- payer_sales_area split above — a Vendor can have different accounting
-- and purchasing terms per org unit, same reasoning as Payer.
CREATE TABLE vendor (
    id              UUID PRIMARY KEY DEFAULT uuidv7(),
    sap_vendor_id   TEXT NOT NULL UNIQUE,  -- SAP-only sourcing (ADR-0002/CONTEXT.md), always present
    name            TEXT NOT NULL,
    address_line1   TEXT,
    address_line2   TEXT,
    city            TEXT,
    state_province  TEXT,
    postal_code     TEXT,
    country         TEXT,
    custom_fields   JSONB NOT NULL DEFAULT '{}'::jsonb,
    status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag   BOOLEAN NOT NULL DEFAULT FALSE,  -- SAP LOEVM-equivalent: marked for archival/removal, distinct from status
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by      UUID
);

-- SAP LFB1-equivalent (Company Code Data). payment_block is included now
-- (rather than deferred to when AP payment processing is built) to keep
-- the LFB1 mapping complete; nothing reads it yet in Phase 1.
CREATE TABLE vendor_company_code (
    id                         UUID PRIMARY KEY DEFAULT uuidv7(),
    vendor_id                  UUID NOT NULL REFERENCES vendor(id),
    company_code               TEXT NOT NULL,
    reconciliation_gl_account  TEXT,
    payment_terms              TEXT,
    accounting_clerk           TEXT,
    payment_block              BOOLEAN NOT NULL DEFAULT FALSE,
    payment_block_reason       TEXT,
    deletion_flag              BOOLEAN NOT NULL DEFAULT FALSE,  -- SAP LOEVM-equivalent, scoped to this company code only
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                 UUID,
    updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                 UUID,
    UNIQUE (vendor_id, company_code)
);
CREATE INDEX ON vendor_company_code (vendor_id);

-- SAP LFM1-equivalent (Purchasing Org Data).
CREATE TABLE vendor_purchasing_org (
    id                     UUID PRIMARY KEY DEFAULT uuidv7(),
    vendor_id              UUID NOT NULL REFERENCES vendor(id),
    purchasing_org         TEXT NOT NULL,
    purchasing_group       TEXT,
    order_currency         TEXT REFERENCES currency(code),
    incoterms_1            TEXT,  -- e.g. 'FOB', 'CIF'
    incoterms_2            TEXT,  -- named place/location qualifying incoterms_1
    planned_delivery_days  INTEGER,
    deletion_flag          BOOLEAN NOT NULL DEFAULT FALSE,  -- SAP LOEVM-equivalent, scoped to this purchasing org only
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by             UUID,
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by             UUID,
    UNIQUE (vendor_id, purchasing_org)
);
CREATE INDEX ON vendor_purchasing_org (vendor_id);

-- SAP LFBK-style: a Vendor may hold more than one bank account (Finding 7).
CREATE TABLE vendor_bank_account (
    id                   UUID PRIMARY KEY DEFAULT uuidv7(),
    vendor_id            UUID NOT NULL REFERENCES vendor(id),
    country              TEXT NOT NULL,
    currency             TEXT NOT NULL,  -- ISO 4217
    bank_name            TEXT,  -- human-readable; needed on remittance advices/payment confirmations, SWIFT/IFSC alone aren't user-facing
    account_holder_name  TEXT,  -- SAP LFBK-KOINH-equivalent; set when the account is held under a different legal name than the Vendor (e.g. factoring)
    routing_no           TEXT,
    account_no           TEXT,
    swift                TEXT,
    ifsc                 TEXT,
    iban                 TEXT,
    is_primary           BOOLEAN NOT NULL DEFAULT FALSE,
    deletion_flag        BOOLEAN NOT NULL DEFAULT FALSE,  -- SAP LOEVM-equivalent, scoped to this bank account only
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           UUID,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by           UUID
);
CREATE INDEX ON vendor_bank_account (vendor_id);
CREATE UNIQUE INDEX ON vendor_bank_account (vendor_id) WHERE is_primary;  -- at most one primary each

-- Payer/Vendor-scoped only (Finding 5) — Tenant Users have no Contact row.
CREATE TABLE contact (
    id             UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id       UUID REFERENCES payer(id),
    vendor_id      UUID REFERENCES vendor(id),
    name           TEXT NOT NULL,
    title          TEXT,  -- e.g. 'AP Clerk', 'Buyer' — RFQ distribution/task assignment routes by role as much as by name
    email          CITEXT,
    phone          TEXT,
    is_primary     BOOLEAN NOT NULL DEFAULT FALSE,
    status         TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag  BOOLEAN NOT NULL DEFAULT FALSE,  -- SAP LOEVM-equivalent, distinct from status
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by     UUID,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by     UUID,
    CONSTRAINT contact_exactly_one_org
        CHECK ((payer_id IS NOT NULL)::int + (vendor_id IS NOT NULL)::int = 1)
);
CREATE INDEX ON contact (payer_id);
CREATE INDEX ON contact (vendor_id);
-- at most one active primary per Payer; same convention as tenant_contact
CREATE UNIQUE INDEX ON contact (payer_id) WHERE is_primary AND status = 'active' AND payer_id IS NOT NULL;
CREATE UNIQUE INDEX ON contact (vendor_id) WHERE is_primary AND status = 'active' AND vendor_id IS NOT NULL;

-- Org affiliation is derived through contact_id (contact.payer_id/vendor_id)
-- rather than duplicating payer_id/vendor_id here — one source of truth.
-- Login/MFA itself is delegated to Cognito (ADR-0006); this row is the
-- "what can they do" half (ADR-0015).
CREATE TABLE app_user (
    id                   UUID PRIMARY KEY DEFAULT uuidv7(),
    cognito_sub          TEXT NOT NULL UNIQUE,
    email                CITEXT NOT NULL UNIQUE,
    phone                TEXT,  -- for Tenant Users, who have no Contact row to carry it (Finding 5)
    is_tenant_user       BOOLEAN NOT NULL DEFAULT FALSE,
    contact_id           UUID REFERENCES contact(id),
    status               TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'deactivated')),
    deactivated_at       TIMESTAMPTZ,
    deactivated_by       UUID REFERENCES app_user(id),
    deactivation_reason  TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           UUID,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by           UUID,
    CONSTRAINT app_user_org_affiliation CHECK (
        (is_tenant_user AND contact_id IS NULL) OR
        (NOT is_tenant_user AND contact_id IS NOT NULL)
    )
);
CREATE INDEX ON app_user (contact_id);
```

The full Security & Roles domain (Authorization Object, Permission, Derived Role, `role_authorization_value`, Role Delegation, Impersonation Session/Action Log) remains **deliberately deferred behind Core AR/AP** — AR is being built before AP end-to-end (confirmed, see [ADR-0021](../adr/0021-parking-lot.md) item 11). One narrow slice of it is pulled forward below, though — not a change of plan, just building the two tables several jobs are already blocked on.

### Domain: Security & Roles — minimal slice only (Parent Roles + `user_role`)

Parking lot items 3 and 6 both needed a real "who is this Tenant's Admin" lookup — `role` + `user_role` are exactly the tables the full Security & Roles domain will need anyway, just built ahead of the rest of it (Authorization Object, Permission, `role_authorization_value`, and Derived Role creation are **not** part of this slice — still deferred). `parent_role_id` is included now, always NULL until Derived Roles are actually built later, specifically so this table never needs an `ALTER` to add it — same "no throwaway work" reasoning as pulling this slice forward at all.

```sql
-- Fixed, AIARAP-defined Parent (master) Roles per ADR-0010 — seeded per
-- {tenant} schema with the same well-known, fixed UUIDs across every
-- Tenant (same convention ADR-0010 already established for Authorization
-- Object/Permission), not a shared global copy.
CREATE TABLE role (
    id                 UUID PRIMARY KEY,  -- fixed, well-known — same value in every Tenant schema
    code               TEXT NOT NULL UNIQUE,  -- 'tenant_admin', 'payer_admin', 'vendor_admin', 'tenant_user', 'payer_user', 'vendor_user'
    name               TEXT NOT NULL,
    parent_role_id     UUID REFERENCES role(id),  -- NULL for every Parent Role seeded here; reserved for Derived Roles once that mechanism is built
    is_system_defined  BOOLEAN NOT NULL DEFAULT TRUE,  -- TRUE for these fixed master roles; FALSE reserved for future Tenant-created Derived Roles
    status             TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         UUID,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by         UUID
);
CREATE INDEX ON role (parent_role_id);

-- Multiple Roles per User (ADR-0010) — total access is the union of every
-- assigned Role's Permissions once those exist; for now this table is
-- what makes "find this Tenant's Admin(s)" a real, indexed query instead
-- of a forward reference.
CREATE TABLE user_role (
    id           UUID PRIMARY KEY DEFAULT uuidv7(),
    app_user_id  UUID NOT NULL REFERENCES app_user(id),
    role_id      UUID NOT NULL REFERENCES role(id),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by   UUID,
    UNIQUE (app_user_id, role_id)
);
CREATE INDEX ON user_role (app_user_id);
CREATE INDEX ON user_role (role_id);
```

**Write-authorization rule for the `tenant_admin` role specifically** (application-layer, not a DB constraint — same convention as other cross-field business rules in this doc): only an existing Tenant Admin may insert a `user_role` row granting `tenant_admin`, except for a Tenant's very first Admin, created by an AIARAP employee (the bootstrap case ADR-0010 already describes to solve the chicken-and-egg problem of an Access Request needing an existing Admin to approve it). No global-schema involvement — this is enforced entirely within the Tenant's own schema, by checking the actor's own `user_role` rows before allowing the insert.

**Scope boundary**: Customer Representative does **not** get a seeded Role row here — a rep accesses a Tenant only via impersonation (`assigned_customer_representative`'s live-check), never as their own `app_user` row in that Tenant's schema, so there's nothing for a Tenant-scoped Role to attach to.

## Domain: Core AR/AP (AR side first)

AP-side entities (Bill, RFQ, PO, Vendor's own transactional documents) are deliberately not started yet — AR is being built end-to-end first. `vendor`/`vendor_bank_account` above were drafted in an earlier bulk pass but not yet reviewed table-by-table; that review is deferred alongside the rest of AP.

```sql
-- SAP TVFK-equivalent (Billing Type customizing), extracted per Tenant
-- rather than seeded — unlike currency (a fixed ISO standard, seeded
-- identically everywhere), SAP billing types are customized per
-- implementation and a Tenant may define its own Z-type codes. Same
-- "reflect the Tenant's own SAP config" reasoning as
-- currency_exchange_rate. Populated by the new Invoice Type Extraction job
-- (0002-scheduled-jobs.md).
CREATE TABLE invoice_type (
    code        TEXT PRIMARY KEY,   -- SAP FKART, e.g. 'F2', 'G2', 'L2', or a Tenant's own custom Z-type
    name        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by  UUID
);

-- SAP-sourced Invoice header, dual-sourced (SAP and optionally Salesforce)
-- like payer — same "at least one source ID present" treatment, unlike
-- vendor's SAP-only sourcing. company_code and sales_org/
-- distribution_channel/division each get a real composite FK (same
-- reasoning as payer_card_payment_policy.company_code) since
-- payer_company_code/payer_sales_area are the local source of truth for
-- which org units exist for this Payer. The sales-area columns are
-- nullable — not every Invoice necessarily has SD/sales-area context (a
-- pure FI-originated invoice might not) — a nullable composite FK simply
-- isn't checked when any column in it is NULL. invoice_type, unlike
-- company_code/sales area, references the new invoice_type table above
-- rather than staying plain TEXT, now that it's extracted per Tenant.
CREATE TABLE invoice (
    id                      UUID PRIMARY KEY DEFAULT uuidv7(),
    sap_invoice_id          TEXT,
    salesforce_invoice_id   TEXT,
    payer_id                UUID NOT NULL REFERENCES payer(id),
    company_code            TEXT NOT NULL,
    sales_org               TEXT,
    distribution_channel    TEXT,
    division                TEXT,
    invoice_type            TEXT NOT NULL REFERENCES invoice_type(code),
    invoice_number          TEXT NOT NULL,  -- SAP-assigned document number, distinct from the internal UUID PK — used for guest lookup (spec: Invoice No + Customer No + Amount)
    fi_document_no          TEXT,  -- SAP BKPF-BELNR — the posted FI/Accounting Document Number for this Invoice
    fi_document_year        TEXT,  -- SAP BKPF-GJAHR — fiscal year component of the FI document key; BELNR is only unique within a fiscal year, hence the pair
    xblnr                   TEXT,  -- SAP XBLNR — free-text Reference Document Number (e.g. a customer PO number), used for external reconciliation/matching
    invoice_date            DATE NOT NULL,
    due_date                DATE,
    total_amount            NUMERIC(18,2) NOT NULL,
    open_amount             NUMERIC(18,2) NOT NULL,  -- DERIVED, not copied from SAP's own balance — total_amount minus SUM(payment.amount WHERE status='posted'), recomputed on every payment insert/reversal; see "Open amount reconciliation" below the payment table for the full mechanism (partial/residual/credit-memo/write-off)
    currency                TEXT NOT NULL REFERENCES currency(code),
    status                  TEXT NOT NULL DEFAULT 'open'
                            CHECK (status IN ('open', 'paid', 'cancelled')),  -- 'paid' follows from open_amount reaching 0 via the derivation above; partial payment is just open_amount < total_amount while status stays 'open'; "overdue" is computed (due_date < today AND status = 'open'), not stored; 'cancelled' is set from is_cancelled below at extraction/sync time, not independently
    is_cancelled            BOOLEAN NOT NULL DEFAULT FALSE,  -- raw SAP cancellation indicator (VBRK-FKSTO / BKPF reversal flag) — the source of truth status='cancelled' is derived from
    original_invoice_id     UUID REFERENCES invoice(id),  -- SAP BSEG-REBZG/REBZJ-equivalent (Invoice Reference): links a Credit/Debit Memo, or a residual invoice created via the "Open amount reconciliation" mechanism below, back to the Invoice it relates to
    custom_fields           JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              UUID,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by              UUID,
    CONSTRAINT invoice_source_id_present
        CHECK (sap_invoice_id IS NOT NULL OR salesforce_invoice_id IS NOT NULL),
    CONSTRAINT invoice_company_code_fk
        FOREIGN KEY (payer_id, company_code)
        REFERENCES payer_company_code (payer_id, company_code),
    CONSTRAINT invoice_sales_area_fk
        FOREIGN KEY (payer_id, sales_org, distribution_channel, division)
        REFERENCES payer_sales_area (payer_id, sales_org, distribution_channel, division)
);
CREATE UNIQUE INDEX ON invoice (sap_invoice_id) WHERE sap_invoice_id IS NOT NULL;
CREATE UNIQUE INDEX ON invoice (salesforce_invoice_id) WHERE salesforce_invoice_id IS NOT NULL;
CREATE INDEX ON invoice (payer_id);
CREATE INDEX ON invoice (payer_id, company_code);
CREATE INDEX ON invoice (payer_id, sales_org, distribution_channel, division);
CREATE INDEX ON invoice (invoice_type);
CREATE INDEX ON invoice (invoice_number);  -- drives guest lookup (Invoice No + Customer No + Amount)
CREATE INDEX ON invoice (status);
CREATE INDEX ON invoice (original_invoice_id);

-- SAP VBRP-equivalent (Billing Document Item). line_amount is stored
-- rather than always computed from quantity * unit_price, since a line can
-- carry its own discount/surcharge adjustments in SAP that wouldn't
-- otherwise be reflected. Account-assignment and reference fields
-- (profit_center through sales_document_item) are all plain TEXT — same
-- "reflect SAP codes, don't own them" treatment as elsewhere in this doc,
-- and they can legitimately differ line-to-line, which is why they live
-- here rather than on the invoice header.
CREATE TABLE invoice_line (
    id                       UUID PRIMARY KEY DEFAULT uuidv7(),
    invoice_id               UUID NOT NULL REFERENCES invoice(id),
    line_number              INTEGER NOT NULL,
    material_id              TEXT,  -- SAP Material Number, when the line is a stocked/catalog item
    description              TEXT NOT NULL,
    quantity                 NUMERIC(15,3),
    uom                      TEXT,  -- SAP MEINS (Unit of Measure), e.g. 'EA', 'KG'
    unit_price               NUMERIC(18,4),
    line_amount              NUMERIC(18,2) NOT NULL,
    currency                 TEXT NOT NULL REFERENCES currency(code),
    profit_center            TEXT,  -- SAP PRCTR
    cost_center              TEXT,  -- SAP KOSTL
    internal_order           TEXT,  -- SAP AUFNR (Internal/Production Order account assignment)
    wbs_element              TEXT,  -- SAP WBS Element (PS_PSP_PNR)
    reference_document       TEXT,  -- SAP VGBEL — preceding document number (per copy control; e.g. a Delivery if billing is delivery-based)
    reference_document_item  TEXT,  -- SAP VGPOS — preceding document's item
    sales_document           TEXT,  -- SAP AUBEL — the originating Sales Order number, regardless of the copy-control chain above
    sales_document_item      TEXT,  -- SAP AUPOS — the originating Sales Order's item
    custom_fields            JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by               UUID,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by               UUID,
    UNIQUE (invoice_id, line_number)
);
CREATE INDEX ON invoice_line (invoice_id);

-- Source-agnostic payment ledger against an Invoice: a payment can be
-- 'aiarap' (AIARAP collected it — currently only via card_payment/Stripe —
-- and wrote the clearing back to SAP itself) or 'sap_native' (the Tenant's
-- own SAP already shows it posted/cleared — a bank transfer, check, or
-- cash payment AIARAP never touched, picked up during Invoice
-- extraction/sync). This table, not card_payment, drives
-- invoice.open_amount and any payment-history/reconciliation view, since
-- those need every payment regardless of source. card_payment is
-- unchanged — kept as the detail table for the AIARAP/Stripe-specific
-- mechanics (charge tracking, SAP write-back retry state) — and is linked
-- here via a nullable FK, set only when source = 'aiarap' and the method
-- is a card.
--
-- NOT ALL "PAYMENT" ROWS ARE CASH — related_invoice_id and
-- settlement_category exist specifically to cover the three ways an
-- Invoice's balance gets settled beyond a plain full/partial cash payment:
--   1. Partial payment: nothing special — a payment row for less than the
--      open balance, invoice stays status='open' with a lower open_amount.
--   2. Residual payment (SAP's real behavior, distinct from partial): the
--      ORIGINAL Invoice is fully cleared even though only part of it was
--      collected in cash, and a brand-new invoice row is created for the
--      uncollected remainder (linked back via that new row's
--      original_invoice_id, mirroring SAP's own Invoice Reference/
--      REBZG-REBZJ). Modeled as TWO payment rows against the original,
--      sharing one sap_clearing_document: one real-cash row
--      (settlement_category='incoming_cash') plus one
--      settlement_category='reallocated' row for the remainder, with
--      related_invoice_id pointing at the new residual invoice — together
--      they sum to the original's full total_amount, closing it out.
--   3. Credit issued to customer (Credit Memo application) / bad debt
--      write-off: non-cash settlement. A Credit Memo is itself an invoice
--      row (its own invoice_type); applying it clears the original
--      Invoice and the Credit Memo against each other in one clearing
--      document — modeled as a payment row on EACH invoice
--      (settlement_category='credit_issued'), each with related_invoice_id
--      pointing at the other. A write-off has no counterpart document at
--      all — one payment row on the Invoice alone
--      (settlement_category='bad_debt_writeoff'), related_invoice_id NULL.
-- settlement_category is a small AIARAP-controlled classification
-- dimension, deliberately separate from payment_method (which stays raw/
-- descriptive — a real SAP ZLSCH code or 'credit_card' — and is NOT
-- reliable to group dashboards by, since sap_native values are
-- uncontrolled free text). It's what drives the AR-cleared-by-category
-- dashboard: sum incoming_cash + credit_issued + bad_debt_writeoff for
-- "AR cleared" in a period, but exclude reallocated — a residual transfer
-- doesn't extinguish or collect anything, it just moves the same
-- outstanding balance onto a new invoice number.
CREATE TABLE payment (
    id                          UUID PRIMARY KEY DEFAULT uuidv7(),
    invoice_id                  UUID NOT NULL REFERENCES invoice(id),
    related_invoice_id          UUID REFERENCES invoice(id),  -- set for 'reallocated' (points at the new residual invoice) and 'credit_issued' (points at the other side's invoice/credit memo); NULL for plain cash and write-offs
    payer_id                    UUID NOT NULL REFERENCES payer(id),
    source                      TEXT NOT NULL CHECK (source IN ('aiarap', 'sap_native')),
    payment_method              TEXT NOT NULL,  -- raw/descriptive: 'credit_card' for aiarap (only method in Phase 1); mirrors SAP's payment method code (ZLSCH) for sap_native, e.g. bank transfer/check/cash; not used for dashboard grouping, see settlement_category
    settlement_category         TEXT NOT NULL
                                CHECK (settlement_category IN ('incoming_cash', 'credit_issued', 'bad_debt_writeoff', 'reallocated')),
    amount                      NUMERIC(18,2) NOT NULL,
    currency                    TEXT NOT NULL REFERENCES currency(code),
    payment_date                DATE NOT NULL,  -- value/clearing date
    sap_clearing_document       TEXT,  -- SAP AUGBL-equivalent — the clearing document number, whether posted by AIARAP's write-back or observed already posted natively in SAP
    sap_clearing_document_year  TEXT,  -- pairs with sap_clearing_document, same fiscal-year-scoping reasoning as invoice.fi_document_year
    payment_reference           TEXT,  -- SAP BSEG-KIDNO (Payment Reference — structured reference used for automatic bank statement/lockbox matching)
    zuonr                       TEXT,  -- SAP BSEG-ZUONR (Assignment)
    sgtxt                       TEXT,  -- SAP BSEG-SGTXT (Item Text — free text entered on the FI line item)
    xref1                       TEXT,  -- SAP BSEG-XREF1 (Business Partner Reference Key)
    xref2                       TEXT,  -- SAP BSEG-XREF2 (Reference Key 2 — e.g. check number)
    xref3                       TEXT,  -- SAP BSEG-XREF3 (Reference Key for the line item, free text)
    vbeln                       TEXT,  -- SAP BSEG sales document reference (first)
    posnr                       TEXT,  -- corresponding item number for vbeln
    vbeln2                      TEXT,  -- SAP BSEG-VBEL2 (Sales Document — secondary/down-payment reference)
    posn2                       TEXT,  -- SAP BSEG-POSN2 (Item of Sales Order, corresponding to vbeln2)
    card_payment_id             UUID REFERENCES card_payment(id),  -- set only when source = 'aiarap' and the method is a card; NULL for sap_native and any future non-card aiarap method
    status                      TEXT NOT NULL DEFAULT 'posted' CHECK (status IN ('posted', 'reversed')),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                  UUID,
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                  UUID
);
CREATE INDEX ON payment (invoice_id);
CREATE INDEX ON payment (related_invoice_id);
CREATE INDEX ON payment (payer_id);
CREATE INDEX ON payment (card_payment_id);
CREATE INDEX ON payment (source);
CREATE INDEX ON payment (settlement_category);
-- Idempotent sync matching: a sync pass discovering SAP-native clearing
-- documents must never insert a duplicate for one already recorded here
-- (whether originally inserted as 'aiarap' once its write-back posted, or
-- from an earlier sync run) — match on this key first, only insert if no
-- row exists.
CREATE UNIQUE INDEX ON payment (invoice_id, sap_clearing_document, sap_clearing_document_year)
    WHERE sap_clearing_document IS NOT NULL;
```

### Open amount reconciliation

`invoice.open_amount` is **derived, not copied from SAP's own extracted balance**:

```
open_amount = total_amount - SUM(amount) OVER payment WHERE invoice_id = :id AND status = 'posted'
```

Recomputed every time a `payment` row is inserted, or an existing one's `status` flips to `'reversed'` (excluded from the sum from that point on). This applies uniformly regardless of `source` or `settlement_category` — a `credit_issued` or `bad_debt_writeoff` row reduces `open_amount` exactly like `incoming_cash` does. The reasoning: every dollar of movement is provable from a `payment` row, rather than trusting a second, independently-computed SAP balance field that could silently disagree with what AIARAP's own records show.

**Two write paths**:
1. **AIARAP-initiated** (`card_payment` succeeds): the app inserts the `payment` row and recomputes `open_amount` immediately, optimistically, before the SAP write-back necessarily succeeds — consistent with [ADR-0019](../adr/0019-automatic-card-payment-batch.md)'s framing that money is already collected the moment Stripe confirms it, and a SAP write-back failure is a bookkeeping gap to close, not a reason to hide the payment from the Payer. `payment.sap_clearing_document` is filled in once the write-back actually posts (mirroring `card_payment.sap_posting_reference`).
2. **Sync-discovered** (`sap_native`): each Invoice sync reconciles the *payment list*, not a balance field — for every clearing document SAP shows against this Invoice, insert a `payment` row (`source = 'sap_native'`) only if one doesn't already exist for that `(invoice_id, sap_clearing_document, sap_clearing_document_year)` (the unique index above enforces this isn't duplicated even across repeated sync runs, and correctly skips a clearing document already recorded as `'aiarap'` once its write-back posted).

**Residual payments and new invoice rows**: when a sync (or the Automatic Card Payment batch, if ever extended to support residual-style short-payment) observes SAP created a residual item, it must also insert the corresponding new `invoice` row for the residual amount (`original_invoice_id` pointing back) — the `reallocated` `payment` row on the original and the new `invoice` row are created together, atomically, or the original's books don't balance.

**Dashboard classification** ("AR cleared in a period, incoming cash vs. credit issued/bad debt write-off"): group `payment` rows by `settlement_category` within the selected `payment_date` range. `incoming_cash` + `credit_issued` + `bad_debt_writeoff` together represent AR genuinely leaving the books; `reallocated` must be **excluded** from any "AR cleared" total — it doesn't collect or forgive anything, it only moves the same outstanding balance onto a new Invoice number.

```sql
-- Inbound event log for the SAP Payment Webhook (ADR-0022) — the Tenant's
-- own SAP system pushes payments it posted natively (bank transfer, check,
-- cash) so AIARAP doesn't have to wait for the next scheduled sync. SAP
-- only ever sends payments IT originated — never AIARAP-originated card
-- payments, which AIARAP already knows about and writes back itself — so
-- every payment row this produces has source = 'sap_native'. Kept
-- structurally separate from payment_provider_webhook_event (Stripe/
-- Payment Provider abstraction, ADR-0001) since this is a different
-- integration boundary — the spec's SAP/Salesforce Integration Adapter
-- seam, not the Payment Provider interface — even though the row shape is
-- similar. event_type is named generically (not "payment_posted" as the
-- table name) since the Tenant's SAP could push other event types later
-- without a new table.
CREATE TABLE sap_webhook_event (
    id                UUID PRIMARY KEY DEFAULT uuidv7(),
    event_type        TEXT NOT NULL,  -- 'payment_posted' is the only type today
    sap_message_id    TEXT,  -- SAP's own message/event identifier, when provided — primary idempotency key
    payload           JSONB NOT NULL,
    status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'processed', 'failed', 'ignored')),
    processed_at      TIMESTAMPTZ,
    processing_error  TEXT,
    received_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        UUID,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by        UUID
);
CREATE INDEX ON sap_webhook_event (status);  -- drives any reprocessing sweep of 'failed'/'pending' rows
-- Idempotency when SAP provides its own message ID; the payment table's
-- own (invoice_id, sap_clearing_document, sap_clearing_document_year)
-- unique index is the ultimate backstop even if this one is skipped
-- (sap_message_id is optional — not every Tenant's outbound mechanism may
-- supply one) or a webhook payload is redelivered without it.
CREATE UNIQUE INDEX ON sap_webhook_event (event_type, sap_message_id) WHERE sap_message_id IS NOT NULL;

-- Inbound event log for AIARAP's Salesforce AppExchange package
-- (ADR-0027) — a third, structurally distinct integration boundary
-- alongside the Payment Provider abstraction (payment_provider_webhook_
-- event, ADR-0001) and the SAP Integration Adapter (sap_webhook_event
-- above). Broader in scope than the SAP webhook: not payment-specific —
-- Salesforce is an alternate system of record for the whole platform
-- (Invoices, Customers, Sales Orders), so event_type is a wide-open
-- discriminator, not narrowed to one flow. Authenticated via OAuth 2.0
-- (salesforce_app_client_id/salesforce_app_client_secret_ref on
-- tenant_settings) rather than a bearer token — Salesforce natively
-- supports OAuth outbound calls via Named/External Credentials, without
-- the custom-signing-code constraint that shaped the SAP webhook's
-- bearer-token choice.
CREATE TABLE salesforce_webhook_event (
    id                  UUID PRIMARY KEY DEFAULT uuidv7(),
    event_type          TEXT NOT NULL,  -- wide open — whatever the installed package is built to send (payment postings, Sales Order events, etc.)
    salesforce_event_id TEXT,  -- Salesforce's own event/message identifier, when provided — primary idempotency key, same pattern as sap_webhook_event.sap_message_id
    payload             JSONB NOT NULL,
    status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'processed', 'failed', 'ignored')),
    processed_at        TIMESTAMPTZ,
    processing_error    TEXT,
    received_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by          UUID
);
CREATE INDEX ON salesforce_webhook_event (status);
CREATE UNIQUE INDEX ON salesforce_webhook_event (event_type, salesforce_event_id) WHERE salesforce_event_id IS NOT NULL;
```

### AR Reconciliation (ADR-0023)

```sql
-- Header: one row per reconciliation run. No single "total variance"
-- column here — SAP AR balances span multiple currencies (a Payer can
-- have foreign-currency Invoices), and summing across currencies would be
-- meaningless. Totals are always broken out by currency, at the account
-- level below.
--
-- trigger_type (parking lot item 27, resolved): a 'scheduled' run always
-- wins on freshness by construction — it does a live SAP pull at the
-- moment it executes, so an earlier webhook push can never be fresher
-- than that. There's no actual "merge" needed between the two. Real-time
-- webhook-pushed balance data (ADR-0022's "critical jobs carry richer
-- payloads" principle) instead triggers its own 'webhook_triggered' run,
-- scoped to just the ONE account the push concerned
-- (accounts_checked = 1), firing immediately rather than waiting for the
-- next scheduled sweep — narrowing the detection window from "up to a
-- day" to "within minutes of a payment posting," without overriding or
-- being overridden by the scheduled run. Both types write to the same
-- account/discrepancy tables below and are kept as separate, independent
-- run rows — full history, nothing deleted or reconciled against the
-- other.
CREATE TABLE ar_reconciliation_run (
    id                      UUID PRIMARY KEY DEFAULT uuidv7(),
    run_date                DATE NOT NULL,
    trigger_type            TEXT NOT NULL DEFAULT 'scheduled'
                            CHECK (trigger_type IN ('scheduled', 'webhook_triggered')),
    accounts_checked        INTEGER NOT NULL DEFAULT 0,
    accounts_with_variance  INTEGER NOT NULL DEFAULT 0,
    status                  TEXT NOT NULL DEFAULT 'completed'
                            CHECK (status IN ('running', 'completed', 'failed')),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              UUID,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by              UUID
);
CREATE INDEX ON ar_reconciliation_run (run_date);
CREATE INDEX ON ar_reconciliation_run (trigger_type);

-- Account-level (Payer + Company Code) rollup — the level requested for
-- identifying discrepancies. Every account gets a row on every run (even
-- variance_amount = 0), so "has this account been clean for N runs" is a
-- direct query, not an absence-based inference. currency is part of the
-- grain, not a column alongside a currency-agnostic total — see note
-- above.
CREATE TABLE ar_reconciliation_account (
    id                   UUID PRIMARY KEY DEFAULT uuidv7(),
    run_id               UUID NOT NULL REFERENCES ar_reconciliation_run(id),
    payer_id             UUID NOT NULL REFERENCES payer(id),
    company_code         TEXT NOT NULL,
    currency             TEXT NOT NULL REFERENCES currency(code),
    sap_open_amount      NUMERIC(18,2) NOT NULL,
    aiarap_open_amount   NUMERIC(18,2) NOT NULL,
    variance_amount      NUMERIC(18,2) NOT NULL,  -- sap_open_amount - aiarap_open_amount; 0 = clean
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           UUID,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by           UUID,
    CONSTRAINT ar_reconciliation_account_company_code_fk
        FOREIGN KEY (payer_id, company_code)
        REFERENCES payer_company_code (payer_id, company_code),
    UNIQUE (run_id, payer_id, company_code, currency)
);
CREATE INDEX ON ar_reconciliation_account (run_id);
CREATE INDEX ON ar_reconciliation_account (payer_id, company_code);
CREATE INDEX ON ar_reconciliation_account (run_id) WHERE variance_amount <> 0;  -- drives "show me this run's discrepancies" dashboard queries

-- Document-level drill-down: which specific Invoices/documents make up a
-- given account's variance.
CREATE TABLE ar_reconciliation_discrepancy (
    id                          UUID PRIMARY KEY DEFAULT uuidv7(),
    reconciliation_account_id  UUID NOT NULL REFERENCES ar_reconciliation_account(id),
    invoice_id                 UUID REFERENCES invoice(id),  -- NULL for missing_in_aiarap — SAP shows an open item AIARAP has no matching Invoice row for at all
    discrepancy_type           TEXT NOT NULL
                               CHECK (discrepancy_type IN ('amount_mismatch', 'missing_in_aiarap', 'missing_in_sap')),
    sap_open_amount            NUMERIC(18,2),  -- NULL for missing_in_sap
    aiarap_open_amount         NUMERIC(18,2),  -- NULL for missing_in_aiarap
    variance_amount            NUMERIC(18,2) NOT NULL,
    sap_document_reference     TEXT,  -- SAP's own document number/year — useful for missing_in_aiarap rows with no invoice_id to join through
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                 UUID,
    updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                 UUID
);
CREATE INDEX ON ar_reconciliation_discrepancy (reconciliation_account_id);
CREATE INDEX ON ar_reconciliation_discrepancy (invoice_id);
```

### AR Aging dashboard configuration

```sql
-- Tenant-configurable AR aging bucket definitions (e.g. 1-30, 31-60,
-- 61-90, 91-180, 180+) driving the AR Aging dashboard. One row per bucket
-- rather than a JSON array on tenant_settings — an aging report needs to
-- range-match Invoices against these boundaries (a direct BETWEEN join),
-- and different Tenants may configure a different NUMBER of buckets, not
-- just different day thresholds. Only covers PAST-DUE buckets — an
-- Invoice not yet past due (due_date >= today) is always its own implicit
-- "Current" bucket in the aging report, not something a Tenant configures
-- here. Tenant-wide, not scoped per Company Code — one bucket set for the
-- whole Tenant.
CREATE TABLE ar_aging_bucket (
    id                  UUID PRIMARY KEY DEFAULT uuidv7(),
    bucket_label        TEXT NOT NULL,  -- e.g. '1-30', '31-60', '61-90', '91-180', '180+'
    min_days_past_due   INTEGER NOT NULL,  -- inclusive
    max_days_past_due   INTEGER,  -- inclusive; NULL = open-ended (the top bucket, e.g. '180+')
    sort_order          INTEGER NOT NULL,
    status              TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by          UUID,
    UNIQUE (sort_order)
);
-- Buckets should be contiguous and non-overlapping (e.g. 1-30 then 31-60,
-- no gap, no overlap) — an application-layer rule enforced when buckets
-- are configured, not a DB constraint, same convention as payer_hierarchy
-- and payer_card_payment_policy's validity-period overlap rules elsewhere
-- in this doc.
```

### AR Aging trend snapshots (ADR-0024) — BI-style pre-computed reporting

Computing aging trend at runtime (which invoices moved between which buckets, over an arbitrary week/month/custom period) is too expensive to do live on every dashboard view, and — critically — distinguishing "the AR team collected past-due balances" from "new invoices are just flowing through Current" requires knowing, per Invoice, which bucket it sat in at each point in time, not just an aggregate total. Bucket-level totals alone are ambiguous: a bucket's total dropping could mean genuine collection, or the same uncollected invoices simply aging into a worse bucket while new ones refill the lower one.

```sql
-- One row per snapshot batch run. Carries both timestamps a user needs to
-- judge data freshness: when the underlying SAP data was last extracted,
-- and when this reporting batch actually processed it into the snapshot
-- below — these can differ (a snapshot can be re-run/refreshed against
-- the same already-extracted SAP data).
CREATE TABLE ar_aging_snapshot_run (
    id                      UUID PRIMARY KEY DEFAULT uuidv7(),
    snapshot_date           DATE NOT NULL,  -- the "as of" business date this aging snapshot represents
    sap_extract_timestamp   TIMESTAMPTZ NOT NULL,  -- when the underlying Invoice/Payment data was last extracted from SAP
    batch_run_at            TIMESTAMPTZ NOT NULL DEFAULT now(),  -- when this batch actually computed the snapshot
    triggered_by            TEXT NOT NULL DEFAULT 'scheduled'
                            CHECK (triggered_by IN ('scheduled', 'manual_refresh')),
    requested_by            UUID REFERENCES app_user(id),  -- set only when triggered_by = 'manual_refresh'
    status                  TEXT NOT NULL DEFAULT 'completed'
                            CHECK (status IN ('running', 'completed', 'failed')),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              UUID,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by              UUID
);
CREATE INDEX ON ar_aging_snapshot_run (snapshot_date);

-- Invoice-level detail — the fact table that makes bucket-migration
-- analysis possible. Joining two runs on invoice_id directly answers
-- "collected" (invoice absent or shrunk in the later run, with a matching
-- payment row in that window) vs. "aged" (same invoice, worse bucket, no
-- payment) vs. "new" (invoice wasn't present in the earlier run) — an
-- aggregate-only table could never disambiguate these. bucket_id NULL =
-- not yet past due (the implicit "Current" bucket, same convention as
-- ar_aging_bucket itself not storing a Current row).
CREATE TABLE ar_aging_snapshot_invoice (
    id                UUID PRIMARY KEY DEFAULT uuidv7(),
    snapshot_run_id   UUID NOT NULL REFERENCES ar_aging_snapshot_run(id),
    invoice_id        UUID NOT NULL REFERENCES invoice(id),
    payer_id          UUID NOT NULL REFERENCES payer(id),
    company_code      TEXT NOT NULL,
    currency          TEXT NOT NULL REFERENCES currency(code),
    bucket_id         UUID REFERENCES ar_aging_bucket(id),
    days_past_due     INTEGER NOT NULL,  -- 0 or negative when not yet due; stored explicitly (not just derived from bucket_id) for precise movement analysis
    open_amount       NUMERIC(18,2) NOT NULL,  -- this Invoice's open_amount as of snapshot_date
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        UUID,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by        UUID,
    CONSTRAINT ar_aging_snapshot_invoice_company_code_fk
        FOREIGN KEY (payer_id, company_code)
        REFERENCES payer_company_code (payer_id, company_code),
    UNIQUE (snapshot_run_id, invoice_id)
);
CREATE INDEX ON ar_aging_snapshot_invoice (invoice_id);
CREATE INDEX ON ar_aging_snapshot_invoice (payer_id, company_code, currency);
CREATE INDEX ON ar_aging_snapshot_invoice (bucket_id);

-- Bucket-level rollup, pre-aggregated from ar_aging_snapshot_invoice at
-- write time — fast headline dashboard reads (e.g. "total in 31-60 for
-- this Payer this week") without summing the detail table on every view.
CREATE TABLE ar_aging_snapshot_bucket (
    id                UUID PRIMARY KEY DEFAULT uuidv7(),
    snapshot_run_id   UUID NOT NULL REFERENCES ar_aging_snapshot_run(id),
    payer_id          UUID NOT NULL REFERENCES payer(id),
    company_code      TEXT NOT NULL,
    currency          TEXT NOT NULL REFERENCES currency(code),
    bucket_id         UUID REFERENCES ar_aging_bucket(id),
    open_amount       NUMERIC(18,2) NOT NULL,
    invoice_count     INTEGER NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        UUID,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by        UUID,
    CONSTRAINT ar_aging_snapshot_bucket_company_code_fk
        FOREIGN KEY (payer_id, company_code)
        REFERENCES payer_company_code (payer_id, company_code)
);
CREATE INDEX ON ar_aging_snapshot_bucket (payer_id, company_code, currency);
-- bucket_id is nullable (Current); NULLs aren't equal to each other under
-- a plain UNIQUE, so uniqueness needs two partial indexes rather than one
-- constraint spanning the nullable column.
CREATE UNIQUE INDEX ON ar_aging_snapshot_bucket (snapshot_run_id, payer_id, company_code, currency, bucket_id)
    WHERE bucket_id IS NOT NULL;
CREATE UNIQUE INDEX ON ar_aging_snapshot_bucket (snapshot_run_id, payer_id, company_code, currency)
    WHERE bucket_id IS NULL;
```

### Stripe payout reconciliation (ADR-0025)

```sql
-- Tenant-editable mapping from Stripe's raw balance_transaction.type enum
-- (charge, refund, payment, adjustment, application_fee,
-- application_fee_refund, transfer, transfer_reversal, stripe_fee,
-- network_cost, tax_fee, reserve_transaction, reserved_funds, payout,
-- payout_cancel, payout_failure, topup, topup_reversal, and more — Stripe's
-- list is large and still growing) down into a small, fixed set of
-- buckets a Tenant's finance team can actually reason about. Seeded with
-- sensible defaults per Tenant schema (same "seeded, then Tenant-
-- editable" pattern as notification_template) — a Tenant can remap a
-- given Stripe type to a different bucket, but the bucket list itself is
-- fixed (the CHECK constraint on stripe_payout_transaction.bucket below);
-- the whole point is simplification, not letting the confusion just move
-- one level up into Tenant-invented bucket names.
CREATE TABLE stripe_transaction_type_bucket (
    id           UUID PRIMARY KEY DEFAULT uuidv7(),
    stripe_type  TEXT NOT NULL UNIQUE,  -- Stripe's raw balance_transaction.type value
    bucket       TEXT NOT NULL
                 CHECK (bucket IN ('charge', 'refund', 'fee', 'reserve', 'payout', 'adjustment', 'transfer', 'other')),
    description  TEXT,
    status       TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by   UUID
);

-- Stripe Payout header — the daily settlement Stripe pays to the Tenant's
-- bank account via their Connected Account (ADR-0020).
CREATE TABLE stripe_payout (
    id                 UUID PRIMARY KEY DEFAULT uuidv7(),
    stripe_payout_id   TEXT NOT NULL UNIQUE,  -- Stripe Payout ID (po_xxx)
    arrival_date       DATE NOT NULL,  -- when funds land in the Tenant's bank account
    amount             NUMERIC(18,2) NOT NULL,  -- net payout amount
    currency           TEXT NOT NULL REFERENCES currency(code),
    status             TEXT NOT NULL,  -- mirrors Stripe's own payout status (paid, pending, failed, canceled)
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         UUID,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by         UUID
);
CREATE INDEX ON stripe_payout (arrival_date);

-- One row per Balance Transaction within a Payout — Stripe's own
-- itemization of what makes up the payout (charges, refunds, fees,
-- adjustments). NOT every row here is AIARAP-originated — the Tenant's
-- Stripe Connected Account can carry charges from SAP-adjacent or other
-- systems sharing the same account. AIARAP-origin is INFERRED, not
-- tagged: matched_card_payment_id is set only when stripe_charge_ref
-- matches an existing card_payment.provider_charge_ref; NULL means this
-- transaction isn't AIARAP's to explain, not an error.
-- gross_amount/fee_amount/net_amount/currency are the SETTLEMENT-side
-- view (the Tenant's payout currency). presentment_amount/
-- presentment_currency/exchange_rate capture the ORIGINAL charge side for
-- a foreign-currency Invoice — Stripe converts at its own rate and that
-- conversion is a separate economic event from its processing fee, which
-- a Tenant's finance team needs to distinguish (FX gain/loss vs. Stripe
-- fees are accounted for completely differently). All three are NULL when
-- no conversion occurred (presentment currency already matches the
-- settlement currency). transaction_type carries an FK to
-- stripe_transaction_type_bucket rather than staying unconstrained — if
-- Stripe introduces a new type not yet mapped, extraction fails loudly
-- (a mapping row needs adding) rather than silently landing in an
-- unrecognized/default bucket. bucket is a denormalized snapshot of that
-- mapping AT INGESTION TIME, not a live join — if a Tenant edits the
-- mapping later, past transactions keep showing the bucket they were
-- actually reported under, same "store what was actually true, not a
-- live-recomputed value" reasoning used for notification.subject/body.
CREATE TABLE stripe_payout_transaction (
    id                       UUID PRIMARY KEY DEFAULT uuidv7(),
    payout_id                UUID NOT NULL REFERENCES stripe_payout(id),
    stripe_balance_txn_id    TEXT NOT NULL UNIQUE,  -- Stripe Balance Transaction ID (txn_xxx)
    stripe_charge_ref        TEXT,  -- Stripe Charge/PaymentIntent ID — the match key against card_payment.provider_charge_ref; NULL for pure fee/adjustment lines with no underlying charge
    transaction_type         TEXT NOT NULL REFERENCES stripe_transaction_type_bucket (stripe_type),  -- Stripe's raw type, e.g. 'charge', 'network_cost', 'reserve_transaction'
    bucket                   TEXT NOT NULL
                             CHECK (bucket IN ('charge', 'refund', 'fee', 'reserve', 'payout', 'adjustment', 'transfer', 'other')),
    gross_amount             NUMERIC(18,2) NOT NULL,
    fee_amount               NUMERIC(18,2) NOT NULL,
    net_amount               NUMERIC(18,2) NOT NULL,
    currency                 TEXT NOT NULL REFERENCES currency(code),
    presentment_amount       NUMERIC(18,2),  -- the original charge amount, in the Invoice's own currency — NULL when no FX conversion occurred
    presentment_currency     TEXT REFERENCES currency(code),  -- NULL under the same condition as presentment_amount
    exchange_rate            NUMERIC(18,6),  -- the rate Stripe itself applied converting presentment_currency to currency — distinct from AIARAP's own currency_exchange_rate table (SAP-sourced); comparing the two is what isolates FX gain/loss from fee_amount
    matched_card_payment_id  UUID REFERENCES card_payment(id),
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by               UUID,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by               UUID
);
CREATE INDEX ON stripe_payout_transaction (payout_id);
CREATE INDEX ON stripe_payout_transaction (bucket);
CREATE INDEX ON stripe_payout_transaction (stripe_charge_ref);
CREATE INDEX ON stripe_payout_transaction (matched_card_payment_id);

-- Reconciliation run + discrepancy, same persisted-not-live pattern as AR
-- Reconciliation (ADR-0023) and AR Aging snapshots (ADR-0024).
CREATE TABLE stripe_reconciliation_run (
    id                 UUID PRIMARY KEY DEFAULT uuidv7(),
    run_date           DATE NOT NULL,
    payouts_checked    INTEGER NOT NULL DEFAULT 0,
    discrepancy_count  INTEGER NOT NULL DEFAULT 0,
    status             TEXT NOT NULL DEFAULT 'completed'
                       CHECK (status IN ('running', 'completed', 'failed')),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         UUID,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by         UUID
);
CREATE INDEX ON stripe_reconciliation_run (run_date);

-- Discrepancy checks apply ONLY to the AIARAP-matched portion of a
-- payout — there's no "missing_in_aiarap" type the way AR Reconciliation
-- has one, since an unmatched Stripe transaction isn't presumed to be
-- AIARAP's in the first place (see stripe_payout_transaction above).
CREATE TABLE stripe_reconciliation_discrepancy (
    id                            UUID PRIMARY KEY DEFAULT uuidv7(),
    run_id                        UUID NOT NULL REFERENCES stripe_reconciliation_run(id),
    card_payment_id               UUID NOT NULL REFERENCES card_payment(id),  -- both discrepancy types start from an AIARAP card_payment row — always set
    stripe_payout_transaction_id  UUID REFERENCES stripe_payout_transaction(id),  -- NULL for missing_in_stripe_extract — nothing to point at yet
    discrepancy_type              TEXT NOT NULL
                                  CHECK (discrepancy_type IN ('amount_mismatch', 'missing_in_stripe_extract')),
    aiarap_amount                 NUMERIC(18,2),
    stripe_amount                 NUMERIC(18,2),  -- NULL for missing_in_stripe_extract
    variance_amount               NUMERIC(18,2) NOT NULL,
    created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                    UUID,
    updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                    UUID
);
CREATE INDEX ON stripe_reconciliation_discrepancy (run_id);
CREATE INDEX ON stripe_reconciliation_discrepancy (card_payment_id);
```

