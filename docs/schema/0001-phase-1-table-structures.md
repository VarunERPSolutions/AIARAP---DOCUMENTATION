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
    status                        TEXT NOT NULL DEFAULT 'provisioning'
                                  CHECK (status IN ('provisioning', 'active', 'suspended', 'deprovisioned')),
    created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                    UUID,
    updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                    UUID
);
-- stripe_connected_account_id used to live here as a single routing-only
-- pointer per Tenant (ADR-0020's original "one connected account per
-- Tenant" design). Removed (ADR-0020 update): Stripe Connect moved to
-- one account per Company Code, so a Tenant can now own several
-- Connected Account IDs — a single column can no longer hold the
-- routing pointer. Replaced by global.stripe_account_routing below, a
-- proper one-row-per-account lookup table.
CREATE TABLE global.stripe_account_routing (
    connected_account_id  TEXT PRIMARY KEY,  -- ROUTING POINTER ONLY, same "opaque ID with no config/credentials attached" treatment the single column used to have — kept here purely so the webhook receiver can resolve the {tenant} schema before it can query anything tenant-specific
    tenant_registry_id     UUID NOT NULL REFERENCES global.tenant_registry(id),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              UUID
);
CREATE INDEX ON global.stripe_account_routing (tenant_registry_id);
-- The authoritative, app-facing copy of each Connected Account ID — plus
-- stripe_enabled and everything else Stripe-related — lives on that
-- Company Code's own row in {tenant}.company_code; the app layer inserts/
-- keeps a matching row here in sync at write time, same denormalization
-- convention used elsewhere in this doc (e.g. card_payment_attempt.payer_id).

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
    -- minimum_card_payment_amount and its ACH/SEPA counterparts moved to
    -- company_code (ADR-0032 update) — see that table's own comment for
    -- why. No tenant-wide minimum-payment fields remain here.
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
    -- Stripe Connect fields (stripe_enabled, stripe_connected_account_id,
    -- stripe_disconnected_at, stripe_payout_interval,
    -- stripe_payout_delay_days) moved to company_code (ADR-0020 update) —
    -- one Connected Account per Company Code, not one per Tenant. See
    -- company_code's own comment for why, and
    -- global.stripe_account_routing for the webhook-routing change this
    -- required.
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
-- company_code (ADR-0020 update, Stripe Connect moved to per-Company-Code)
-- is now required and structural, not just informational: a Stripe
-- Connect Standard account is a genuinely separate underlying Stripe
-- account per Company Code, so a card token
-- (provider_payment_method_ref) registered under one Company Code's
-- account is NOT valid/chargeable under another — the Payer must register
-- separately per Company Code if they have open Invoices under more than
-- one. allow_child_use sharing is scoped by the SAME company_code as a
-- consequence (a shared card only works for a child Payer's charges under
-- that identical Company Code, checked at the application layer alongside
-- the existing payer_hierarchy check). is_primary is now scoped per
-- (payer_id, company_code), not per Payer alone, for the same reason.
CREATE TABLE payer_payment_card (
    id                           UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id                     UUID NOT NULL REFERENCES payer(id),  -- owning Payer
    company_code                 TEXT NOT NULL REFERENCES company_code(code),  -- which Company Code's Stripe Connected Account this token was registered under
    provider                     TEXT NOT NULL DEFAULT 'stripe',      -- generic per ADR-0001; not assumed to stay Stripe-only
    provider_customer_ref        TEXT,           -- e.g. Stripe Customer ID (cus_xxx)
    provider_payment_method_ref  TEXT NOT NULL,  -- e.g. Stripe PaymentMethod ID (pm_xxx) — the actual token
    card_brand                   TEXT,           -- 'visa', 'mastercard', ... — safe, non-sensitive metadata returned by the provider
    card_last4                   TEXT,
    card_exp_month               SMALLINT,
    card_exp_year                SMALLINT,
    is_primary                   BOOLEAN NOT NULL DEFAULT FALSE,
    allow_child_use              BOOLEAN NOT NULL DEFAULT FALSE,  -- can a child Payer (per payer_hierarchy, any sales area, currently valid) charge this card, for that same company_code's Invoices?
    consecutive_failed_attempts  INTEGER NOT NULL DEFAULT 0,  -- reset to 0 on any successful card_payment_attempt; incremented on each failed one, drives auto_pay_blocked below (ADR-0019)
    auto_pay_blocked             BOOLEAN NOT NULL DEFAULT FALSE,  -- set once consecutive_failed_attempts reaches tenant_settings.card_auto_pay_max_failed_attempts — excludes this card from the Automatic Card Payment batch ONLY; distinct from status, since the Payer can still see/retry it manually in the portal
    auto_pay_blocked_at          TIMESTAMPTZ,
    status                       TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag                BOOLEAN NOT NULL DEFAULT FALSE,
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                   UUID,
    updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                   UUID,
    CONSTRAINT payer_payment_card_company_code_fk
        FOREIGN KEY (payer_id, company_code)
        REFERENCES payer_company_code (payer_id, company_code),
    UNIQUE (provider, provider_payment_method_ref),
    UNIQUE (id, company_code)  -- enables payer_card_payment_policy's composite FK below, ensuring a policy's company_code always matches its card's own
);
CREATE INDEX ON payer_payment_card (payer_id);
CREATE INDEX ON payer_payment_card (payer_id, company_code);
-- at most one active primary per Payer PER Company Code (not per Payer alone — a Payer can have a distinct primary card per Company Code's Stripe account)
CREATE UNIQUE INDEX ON payer_payment_card (payer_id, company_code) WHERE is_primary AND status = 'active';

-- Per-card policy: which Invoice types a specific stored card may be used
-- for, within what Company Code, within what time window, and up to what
-- amount per charge. invoice_type now references the invoice_type table
-- (Core AR/AP domain, further down this file — extracted per Tenant from
-- their SAP billing-type customizing, TVFK-equivalent) rather than staying
-- plain TEXT — a forward reference within this doc, same as company_code
-- below now is against the company_code table (further down this file
-- still at the time this comment was written, promoted alongside Sales
-- Order checkout, ADR-0029). company_code also gets a real composite FK
-- into payer_company_code — payer_company_code is the local source of
-- truth for which company codes exist for this Payer (not mirrored SAP
-- data with nothing local to check against), preventing a policy from ever
-- pointing at a company code the Payer doesn't actually have on file.
-- payer_id is denormalized alongside payer_payment_card_id for query
-- convenience — the app layer keeps it consistent with the card's own
-- payer_id at write time, same as the overlap rule below.
-- payer_card_payment_policy_card_company_code_fk (ADR-0020 update) is new:
-- since payer_payment_card.company_code is now structural (a card only
-- exists within one Company Code's Stripe Connected Account), a policy's
-- own company_code must match the card it's authorizing — enforced as a
-- real composite FK against payer_payment_card's own (id, company_code)
-- uniqueness, not just an app-layer check, so a policy can never
-- reference a company_code its card wasn't actually registered under.
CREATE TABLE payer_card_payment_policy (
    id                     UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id               UUID NOT NULL REFERENCES payer(id),
    payer_payment_card_id  UUID NOT NULL REFERENCES payer_payment_card(id),
    company_code           TEXT NOT NULL REFERENCES company_code(code),
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
    CONSTRAINT payer_card_payment_policy_card_company_code_fk
        FOREIGN KEY (payer_payment_card_id, company_code)
        REFERENCES payer_payment_card (id, company_code),
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

-- ACH/SEPA bank debit (ADR-0032) — a PARALLEL structure to
-- payer_payment_card above, not a generalization of it. Deliberately kept
-- separate: bank debits have no expiry concept (no card_exp_month/year
-- equivalent), need method-specific verification/mandate tracking cards
-- never had, and settle over days rather than instantly — retrofitting
-- the card tables to cover this would have touched every already-built
-- card-payment ADR/job in this doc for no real benefit. method_type splits
-- ACH (US) from SEPA (EU) since their verification and mandate mechanics
-- differ; sepa_mandate_* columns are SEPA-only (NULL for ACH), same
-- nullable-when-not-applicable treatment used elsewhere in this doc.
-- self_imposed_limit_* is a Payer-SELF-DECLARED cap set at registration
-- time (not a Tenant-configured policy — there is deliberately no
-- payer_bank_account_payment_policy mirroring payer_card_payment_policy;
-- this simpler single cap was chosen instead) — the Payer's own stated
-- reason for it is being able to tell their own bank a hard ceiling on
-- what AIARAP will ever pull, checked as a hard outer bound before any
-- charge attempt.
-- company_code (ADR-0020 update, same reasoning as payer_payment_card's
-- own company_code retrofit): Stripe Connect moved to per-Company-Code,
-- so an ACH/SEPA PaymentMethod token is likewise only valid within the
-- one Company Code's Connected Account it was registered under.
CREATE TABLE payer_bank_account (
    id                           UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id                     UUID NOT NULL REFERENCES payer(id),
    company_code                 TEXT NOT NULL REFERENCES company_code(code),
    method_type                  TEXT NOT NULL CHECK (method_type IN ('ach', 'sepa')),
    provider                     TEXT NOT NULL DEFAULT 'stripe',
    provider_customer_ref        TEXT,           -- e.g. Stripe Customer ID (cus_xxx)
    provider_payment_method_ref  TEXT NOT NULL,  -- e.g. Stripe PaymentMethod ID (pm_xxx) for a us_bank_account or sepa_debit type
    bank_name                    TEXT,
    account_last4                TEXT,
    account_holder_name          TEXT,
    country                      TEXT,
    currency                     TEXT REFERENCES currency(code),  -- the account's own currency — USD for ACH, EUR for SEPA in practice, not hardcoded either way
    verification_method          TEXT CHECK (verification_method IN ('instant', 'microdeposit')),  -- Financial-Connections/Plaid-style instant verification, or the 2-small-deposit fallback when instant isn't available for a given bank
    verification_status          TEXT NOT NULL DEFAULT 'pending' CHECK (verification_status IN ('pending', 'verified', 'failed')),
    sepa_mandate_reference        TEXT,  -- SEPA only — the signed mandate's own reference/ID; SEPA legally requires this before any debit, unlike ACH
    sepa_mandate_signed_at        TIMESTAMPTZ,  -- SEPA only
    self_imposed_limit_amount     NUMERIC(18,2),
    self_imposed_limit_period     TEXT CHECK (self_imposed_limit_period IN ('per_charge', 'monthly')),  -- 'monthly' is CALENDAR month (resets the 1st), not a rolling window — parking lot item 49, resolved. Evaluated live at each charge attempt: sum this account's own successful (non-returned) bank_debit_payment amounts from the 1st of the current calendar month through now; skip the charge if adding it would exceed self_imposed_limit_amount. No separate tracking table (unlike card_payment_threshold_exceeded) — that exists for FX-conversion complexity this doesn't have; a failed check just logs as a normal bank_debit_payment_attempt (outcome='failed')
    self_imposed_limit_currency   TEXT REFERENCES currency(code),
    is_primary                    BOOLEAN NOT NULL DEFAULT FALSE,
    allow_child_use               BOOLEAN NOT NULL DEFAULT FALSE,  -- can a child Payer (per payer_hierarchy) charge this bank account? Same convention as payer_payment_card.allow_child_use
    consecutive_failed_attempts   INTEGER NOT NULL DEFAULT 0,  -- reset to 0 on any successful bank_debit_payment_attempt; drives auto_pay_blocked, same convention as payer_payment_card
    auto_pay_blocked              BOOLEAN NOT NULL DEFAULT FALSE,
    auto_pay_blocked_at           TIMESTAMPTZ,
    status                        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag                 BOOLEAN NOT NULL DEFAULT FALSE,
    created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                    UUID,
    updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                    UUID,
    CONSTRAINT payer_bank_account_company_code_fk
        FOREIGN KEY (payer_id, company_code)
        REFERENCES payer_company_code (payer_id, company_code),
    UNIQUE (provider, provider_payment_method_ref)
);
CREATE INDEX ON payer_bank_account (payer_id);
CREATE INDEX ON payer_bank_account (payer_id, company_code);
-- at most one active primary per Payer PER Company Code, same convention as payer_payment_card
CREATE UNIQUE INDEX ON payer_bank_account (payer_id, company_code) WHERE is_primary AND status = 'active';

-- Mirrors card_payment, with settlement/return handling cards never
-- needed: charged_at is when Stripe reported the debit as 'succeeded' —
-- treated as sufficient to write back to SAP immediately and mark the
-- Invoice paid (ADR-0032's optimistic-settlement decision), NOT gated on
-- settlement_status reaching 'settled'. settlement_status tracks the
-- multi-day bank-side outcome separately, for visibility, not as a gate.
-- A late 'returned' event doesn't get its own reversal state machine here
-- — it flips the already-created payment row (linked via
-- payment.bank_debit_payment_id, mirroring payment.card_payment_id
-- exactly) to status = 'reversed', reusing invoice.open_amount's existing
-- derivation (SUM(payment.amount WHERE status='posted') already excludes
-- reversed rows) rather than inventing new derivation logic for this one
-- payment method.
CREATE TABLE bank_debit_payment (
    id                        UUID PRIMARY KEY DEFAULT uuidv7(),
    invoice_id                UUID NOT NULL REFERENCES invoice(id),
    payer_id                  UUID NOT NULL REFERENCES payer(id),
    payer_bank_account_id     UUID NOT NULL REFERENCES payer_bank_account(id),
    initiated_via             TEXT NOT NULL DEFAULT 'auto_batch'
                              CHECK (initiated_via IN ('auto_batch', 'manual_portal')),
    amount                    NUMERIC(18,2) NOT NULL,
    currency                  TEXT NOT NULL REFERENCES currency(code),
    provider                  TEXT NOT NULL DEFAULT 'stripe',
    provider_charge_ref       TEXT NOT NULL,
    provider_fee_amount       NUMERIC(18,2),  -- gross/fee/net breakdown, same role as card_payment.provider_fee_amount — this is exactly the fee saving driving ADR-0032 (ACH/SEPA fees are typically flat/small vs. card interchange)
    charged_at                TIMESTAMPTZ NOT NULL,
    settlement_status         TEXT NOT NULL DEFAULT 'pending'
                              CHECK (settlement_status IN ('pending', 'settled', 'returned')),
    settled_at                TIMESTAMPTZ,
    returned_at               TIMESTAMPTZ,
    return_code               TEXT,  -- e.g. ACH return codes (R01 Insufficient Funds, R02 Account Closed, R10 Unauthorized) or SEPA reason codes (AC04, AM04, MD01)
    return_reason              TEXT,
    sap_posting_status        TEXT NOT NULL DEFAULT 'pending'
                              CHECK (sap_posting_status IN ('pending', 'posted', 'failed')),
    sap_posting_reference     TEXT,
    sap_posting_attempts      INTEGER NOT NULL DEFAULT 0,
    sap_posting_last_error    TEXT,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                UUID,
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                UUID,
    UNIQUE (provider, provider_charge_ref)
);
CREATE INDEX ON bank_debit_payment (invoice_id);
CREATE INDEX ON bank_debit_payment (payer_id);
CREATE INDEX ON bank_debit_payment (payer_bank_account_id);
CREATE INDEX ON bank_debit_payment (sap_posting_status);  -- drives the SAP write-back retry sweep
-- drives the sweep watching for late return events / settlement confirmation
CREATE INDEX ON bank_debit_payment (settlement_status) WHERE settlement_status = 'pending';

-- Mirrors card_payment_attempt exactly, minus a policy_id — there is no
-- payer_bank_account_payment_policy to authorize against (see
-- payer_bank_account's self_imposed_limit_* comment above for why).
CREATE TABLE bank_debit_payment_attempt (
    id                      UUID PRIMARY KEY DEFAULT uuidv7(),
    invoice_id              UUID NOT NULL REFERENCES invoice(id),
    payer_id                UUID NOT NULL REFERENCES payer(id),
    payer_bank_account_id   UUID NOT NULL REFERENCES payer_bank_account(id),
    initiated_via           TEXT NOT NULL DEFAULT 'auto_batch'
                            CHECK (initiated_via IN ('auto_batch', 'manual_portal')),
    attempted_amount        NUMERIC(18,2) NOT NULL,
    attempted_currency      TEXT NOT NULL REFERENCES currency(code),
    provider                TEXT NOT NULL DEFAULT 'stripe',
    provider_request_ref    TEXT,
    outcome                 TEXT NOT NULL CHECK (outcome IN ('succeeded', 'failed')),
    failure_code            TEXT,
    failure_message         TEXT,
    bank_debit_payment_id   UUID REFERENCES bank_debit_payment(id),  -- set when outcome = 'succeeded'
    attempted_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              UUID
);
CREATE INDEX ON bank_debit_payment_attempt (invoice_id);
CREATE INDEX ON bank_debit_payment_attempt (payer_id);
CREATE INDEX ON bank_debit_payment_attempt (payer_bank_account_id);

-- Log of every incoming Payment Provider webhook event (ADR-0020), named
-- generically per ADR-0001 rather than Stripe-specific — not scoped to
-- card-data updates only, so any future webhook-driven event (e.g. charge
-- confirmation) reuses the same table rather than forking a new one.
-- By the time an event reaches this table, the webhook receiver has
-- already resolved which {tenant} schema to write into via
-- global.stripe_account_routing (ADR-0032 update — replaced the old
-- single-column pointer on global.tenant_registry) — this table only
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

-- SAP T001-equivalent (Company Code master data). Promoted from plain TEXT
-- to a real reference table for the same reason invoice_type was further
-- down this file: it now needs to carry real config, not just act as a
-- label. down_payment_configured tracks whether this Company Code's SAP
-- has FI Down Payment (special G/L indicator + alternative reconciliation
-- account) correctly set up — checked at Sales Order checkout time (ADR-
-- 0029) before AIARAP will let a Payer complete checkout under this
-- Company Code. Deliberately Company-Code-grained, not a single Tenant-
-- wide flag: this SAP config is maintained per Company Code, so a Tenant
-- with multiple Company Codes (e.g. a later-onboarded subsidiary) can
-- easily have it configured correctly in one and not another.
-- down_payment_verified_at/_by is a manual confirmation step, not a
-- self-service toggle — same treatment as stripe_enabled below only being
-- flipped once Stripe Connect onboarding is actually confirmed, not
-- automatically. Extracted per Tenant like invoice_type (a Tenant's
-- own Company Code structure, not fixed/seeded reference data like
-- currency).
-- minimum_{card,ach,sepa}_payment_amount/_currency (ADR-0032 update) were
-- originally proposed on tenant_settings (one flat platform-wide number),
-- moved here instead — same Company-Code-grained reasoning as
-- down_payment_configured: a Tenant with multiple Company Codes may want
-- different minimum-payment thresholds per one, not a single Tenant-wide
-- setting.
-- stripe_* fields (ADR-0020 update) were also originally on
-- tenant_settings (one Stripe Connected Account per Tenant) — moved here
-- because a Stripe Connect Standard account is a genuinely separate
-- underlying Stripe account, and a Tenant with multiple Company Codes
-- (separate legal entities/bank accounts) needs each one to settle
-- payouts into its own bank account via its own Connected Account, not a
-- single Tenant-wide one. This is a real reopening of ADR-0020's "one
-- connected account per Tenant" premise — see that ADR's own update note.
-- stripe_connected_account_id no longer has a single-column routing
-- pointer on global.tenant_registry (a Tenant can now own several) — see
-- global.stripe_account_routing below, a proper lookup table replacing it.
-- bank_debit_order_confirmation_mode (ADR-0032 update) governs Sales
-- Order checkout (ADR-0029) specifically for payment_method IN
-- ('ach', 'sepa') — since ADR-0032's optimistic-settlement decision means
-- a Sales Order could otherwise be created (and fulfillment begun) in SAP
-- on a charge that isn't actually final for days, a Tenant can choose per
-- Company Code: 'hold_in_aiarap' (don't call SAP to create the order at
-- all until sales_order_payment.settlement_status reaches 'settled' —
-- the charge itself still happens immediately, only SAP order creation
-- waits) or 'submit_with_delivery_block' (create the SAP Sales Order
-- immediately as before, but with SAP's own Delivery Block — VBAK-LIFSK
-- — set, cleared only once settlement is confirmed). Does not apply to
-- 'credit_card' orders (no equivalent settlement delay) or
-- 'purchase_order' orders (never charged at checkout). See the new Sales
-- Order Bank-Debit Confirmation Batch job (0002-scheduled-jobs.md) that
-- acts on whichever mode applies.
CREATE TABLE company_code (
    code                             TEXT PRIMARY KEY,  -- SAP BUKRS
    name                             TEXT NOT NULL,
    down_payment_configured          BOOLEAN NOT NULL DEFAULT FALSE,
    down_payment_verified_at         TIMESTAMPTZ,
    down_payment_verified_by      UUID,
    minimum_card_payment_amount   NUMERIC(14,3) NOT NULL DEFAULT 0,  -- ADR-0032: moved here from tenant_settings, same Company-Code grain as down_payment_configured above — a Tenant with multiple Company Codes may want different minimums per one, not one flat platform-wide number. Scale 3 for 3-decimal currencies (BHD/KWD/OMR); decimal-place validation against currency.minor_unit happens at the application layer, same as everywhere else in this doc. Rationale is card processing fee economics (spec story 12).
    minimum_card_payment_currency  TEXT NOT NULL DEFAULT 'USD' REFERENCES currency(code),
    minimum_ach_payment_amount     NUMERIC(14,3) NOT NULL DEFAULT 0,  -- independently tunable from the card minimum — ACH's fee economics differ
    minimum_ach_payment_currency   TEXT NOT NULL DEFAULT 'USD' REFERENCES currency(code),
    minimum_sepa_payment_amount    NUMERIC(14,3) NOT NULL DEFAULT 0,  -- kept separate from the ACH minimum — different region, different fee structure
    minimum_sepa_payment_currency  TEXT NOT NULL DEFAULT 'EUR' REFERENCES currency(code),
    stripe_enabled                 BOOLEAN NOT NULL DEFAULT FALSE,  -- ADR-0020 update: moved from tenant_settings — not every Company Code uses Stripe/card+ACH+SEPA payments; gates the Automatic Card Payment batch, Automatic Bank Debit Payment batch, Card Expiry Alert, and webhook processing for this Company Code
    stripe_connected_account_id    TEXT UNIQUE,  -- authoritative, app-facing copy; global.stripe_account_routing keeps the routing-only lookup entry, kept in sync at write time
    stripe_disconnected_at         TIMESTAMPTZ,  -- set when this Company Code disconnects Stripe; stripe_connected_account_id is deliberately NOT cleared — kept as a historical record, same "deactivation not deletion" convention used elsewhere, so any late in-flight webhook for a pre-disconnect charge still resolves correctly rather than being orphaned
    stripe_payout_interval          TEXT CHECK (stripe_payout_interval IN ('daily', 'weekly', 'monthly', 'manual')),  -- synced from Stripe's Account API (settings.payouts.schedule), not manually configured — refreshed by the Stripe Payout Reconciliation job (ADR-0025) each run
    stripe_payout_delay_days        INTEGER,  -- synced alongside stripe_payout_interval; drives the reconciliation grace-period window (parking lot item 23) — NULL until first synced, in which case the job falls back to the 5-day platform default
    bank_debit_order_confirmation_mode  TEXT NOT NULL DEFAULT 'submit_with_delivery_block'
                                        CHECK (bank_debit_order_confirmation_mode IN ('hold_in_aiarap', 'submit_with_delivery_block')),
    created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                    UUID,
    updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                    UUID
);

-- SAP TVKO-equivalent (Sales Organizations). Extracted per Tenant like
-- company_code above — a Tenant's own SD org structure, not fixed/seeded
-- reference data.
CREATE TABLE sales_org (
    code          TEXT PRIMARY KEY,  -- SAP VKORG
    name          TEXT NOT NULL,
    company_code  TEXT NOT NULL REFERENCES company_code(code),  -- SAP TVKO-BUKRS: a Sales Org belongs to exactly one Company Code
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    UUID,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by    UUID
);
CREATE INDEX ON sales_org (company_code);

-- SAP T001W-equivalent (Plants/Branches). Extracted per Tenant. Kept
-- standalone (no direct company_code column) — its Company Code
-- relationship goes through company_code_plant below, since real SAP
-- plant-to-company-code assignment is indirect (via Valuation Area), not a
-- plain 1:1 column.
CREATE TABLE plant (
    code            TEXT PRIMARY KEY,  -- SAP WERKS
    name            TEXT NOT NULL,
    address_line1   TEXT,
    address_line2   TEXT,
    city            TEXT,
    state_province   TEXT,
    postal_code      TEXT,
    country          TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       UUID,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by       UUID
);

-- Phase 2 scope (ADR-0035) — AP moved to Phase 2 in its entirety, not just
-- sequenced after AR (superseding the "parking lot item 11" reasoning this
-- comment originally cited). purchase_org and its two assignment tables
-- immediately below (purchase_org_company_code, purchase_org_plant) are
-- kept as already-designed DDL, not deployed/migrated as part of Phase 1 —
-- re-derive nothing here when AP work resumes. (company_code_plant,
-- sales_org_distribution_channel_plant, payer_sales_area, and
-- payer_company_code further down are general/AR-side master data, not
-- part of this Phase 2 scope note — see the separate note before `vendor`.)
--
-- SAP T024E-equivalent (Purchasing Organizations). AP-domain master data —
-- deliberately kept a bare master table for now (vendor_purchasing_org is
-- not retrofitted to reference this yet), but its two assignment tables
-- below were built alongside it per an earlier session's request rather
-- than waiting for the full AP domain review pass.
CREATE TABLE purchase_org (
    code        TEXT PRIMARY KEY,  -- SAP EKORG
    name        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by  UUID
);

-- SAP's "Assign Purchasing Organization to Company Code" config (a
-- Purchasing Org configured as company-code-specific, usable across every
-- Plant belonging to that Company Code). Not mutually exclusive with
-- purchase_org_plant below — a real SAP Purchasing Org can be assigned
-- either way, or both (a "reference"/shared Purchasing Org spanning
-- multiple Company Codes is a further real-world variant, not modeled here
-- — out of scope until an actual Tenant needs it).
CREATE TABLE purchase_org_company_code (
    purchase_org  TEXT NOT NULL REFERENCES purchase_org(code),
    company_code  TEXT NOT NULL REFERENCES company_code(code),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    UUID,
    PRIMARY KEY (purchase_org, company_code)
);
CREATE INDEX ON purchase_org_company_code (company_code);

-- SAP's "Assign Purchasing Organization to Plant" config (plant-specific
-- Purchasing Org, potentially spanning multiple Company Codes).
CREATE TABLE purchase_org_plant (
    purchase_org  TEXT NOT NULL REFERENCES purchase_org(code),
    plant         TEXT NOT NULL REFERENCES plant(code),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    UUID,
    PRIMARY KEY (purchase_org, plant)
);
CREATE INDEX ON purchase_org_plant (plant);

-- SAP T001K-equivalent (Valuation Area assigned to Company Code),
-- simplified to Plant directly (Valuation Area = Plant in the common,
-- non-split-valuation case — a genuine 1:many Valuation-Area-to-Plant
-- split is a further real-world variant not modeled here).
CREATE TABLE company_code_plant (
    company_code  TEXT NOT NULL REFERENCES company_code(code),
    plant         TEXT NOT NULL REFERENCES plant(code),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    UUID,
    PRIMARY KEY (company_code, plant)
);
CREATE INDEX ON company_code_plant (plant);

-- SAP TVKWZ-equivalent ("Assign plant for sales org/distribution
-- channel") — the real, 3-part grain: the same Sales Org can deliver from
-- different Plants depending on Distribution Channel, so a flat
-- Sales-Org-to-Plant mapping (2-part) would be insufficient.
-- distribution_channel stays plain TEXT here, consistent with its
-- treatment everywhere else in this doc (payer_sales_area, invoice) — only
-- sales_org and plant have been promoted to real reference tables this
-- session, not distribution_channel/division.
CREATE TABLE sales_org_distribution_channel_plant (
    sales_org             TEXT NOT NULL REFERENCES sales_org(code),
    distribution_channel  TEXT NOT NULL,
    plant                 TEXT NOT NULL REFERENCES plant(code),
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            UUID,
    PRIMARY KEY (sales_org, distribution_channel, plant)
);
CREATE INDEX ON sales_org_distribution_channel_plant (plant);

-- SAP KNVV-equivalent (Sales Area Data), kept minimal: a Payer can have
-- different sales terms per Sales Org + Distribution Channel + Division.
-- sales_org and shipping_plant now carry real FKs (retrofitted alongside
-- sales_org/plant's creation, ADR-0029), same "promote once a real
-- reference table exists" treatment as company_code above.
-- distribution_channel/division stay plain TEXT — not promoted this
-- session.
CREATE TABLE payer_sales_area (
    id                          UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id                    UUID NOT NULL REFERENCES payer(id),
    sales_org                   TEXT NOT NULL REFERENCES sales_org(code),
    distribution_channel        TEXT NOT NULL,
    division                    TEXT NOT NULL,
    currency                    TEXT REFERENCES currency(code),
    payment_terms               TEXT,
    price_group                 TEXT,
    incoterms_1                 TEXT,  -- Incoterms classification, e.g. 'FOB', 'CIF'
    incoterms_2                 TEXT,  -- named place/location qualifying incoterms_1, e.g. 'Mumbai Port'
    customer_group              TEXT,
    shipping_plant              TEXT REFERENCES plant(code),  -- delivering plant
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
CREATE INDEX ON payer_sales_area (sales_org);
CREATE INDEX ON payer_sales_area (shipping_plant);

-- SAP KNB1-equivalent (Company Code Data), kept minimal: a Payer can have
-- different accounting terms per Company Code. company_code now carries a
-- real FK to the company_code table above (retrofitted alongside its
-- creation, ADR-0029) rather than staying plain TEXT.
CREATE TABLE payer_company_code (
    id                         UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id                   UUID NOT NULL REFERENCES payer(id),
    company_code               TEXT NOT NULL REFERENCES company_code(code),
    reconciliation_gl_account  TEXT,
    payment_terms              TEXT,
    accounting_clerk_user_id   UUID REFERENCES app_user(id),  -- SAP KNB1-BUSAB-equivalent, but a real AIARAP account (not a code string) so it's an actual notification target — resolves "AR Clerk" for ADR-0019's SAP write-back failure alert, avoids inundating a single Tenant Admin
    dunning_clerk              TEXT,
    statement_frequency        TEXT,  -- e.g. 'monthly', 'weekly', 'on-demand'
    credit_limit               NUMERIC(18,2),  -- SAP FD32/KNKK-equivalent, scoped to this company code
    credit_hold                BOOLEAN NOT NULL DEFAULT FALSE,  -- AR-side counterpart to vendor_company_code.payment_block
    credit_hold_reason         TEXT,
    po_order_allowed           BOOLEAN NOT NULL DEFAULT FALSE,  -- gates sales_order.payment_method = 'purchase_order' (ADR-0029 update) — bill-on-account/net-terms checkout is only offered to approved customers, checked at the application layer against this flag; net terms themselves reuse payment_terms above, no separate field needed
    po_order_approved_at       TIMESTAMPTZ,  -- manual approval step, not self-service — same treatment as company_code.down_payment_verified_at
    po_order_approved_by       UUID REFERENCES app_user(id),
    deletion_flag              BOOLEAN NOT NULL DEFAULT FALSE,  -- SAP LOEVM-equivalent, scoped to this company code only
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                 UUID,
    updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                 UUID,
    UNIQUE (payer_id, company_code)
);
CREATE INDEX ON payer_company_code (payer_id);
CREATE INDEX ON payer_company_code (accounting_clerk_user_id);

-- Phase 2 scope (ADR-0035) — vendor and its 3 child tables below
-- (vendor_company_code, vendor_purchasing_org, vendor_bank_account) are
-- kept as already-designed DDL, not deployed/migrated as part of Phase 1.
--
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
-- sales area, references the new invoice_type table above rather than
-- staying plain TEXT, now that it's extracted per Tenant. company_code
-- additionally carries a plain (non-composite) FK into the company_code
-- table itself, alongside its existing composite FK into
-- payer_company_code below — retrofitted alongside company_code's
-- creation (ADR-0029), same treatment given to
-- payer_company_code.company_code and
-- payer_card_payment_policy.company_code.
CREATE TABLE invoice (
    id                      UUID PRIMARY KEY DEFAULT uuidv7(),
    sap_invoice_id          TEXT,
    salesforce_invoice_id   TEXT,
    payer_id                UUID NOT NULL REFERENCES payer(id),
    company_code            TEXT NOT NULL REFERENCES company_code(code),
    sales_org               TEXT REFERENCES sales_org(code),  -- nullable, same as the composite FK below — a pure FI-originated invoice may carry no sales-area context at all
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
CREATE INDEX ON invoice (sales_org);
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
    payment_method              TEXT NOT NULL,  -- raw/descriptive: 'credit_card', 'ach', or 'sepa' for aiarap (ADR-0032 added the latter two); mirrors SAP's payment method code (ZLSCH) for sap_native, e.g. bank transfer/check/cash; not used for dashboard grouping, see settlement_category
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
    sales_order_payment_id      UUID REFERENCES sales_order_payment(id),  -- forward reference — sales_order_payment is defined later in this doc (Sales Order Checkout domain, ADR-0029), same forward-reference treatment already used elsewhere (e.g. invoice_type). Set only when this row was created by AIARAP driving the FI Down Payment clearing (see sales_order_payment below) against the Invoice this Sales Order eventually generated; NULL for every other payment row, including card_payment-sourced ones. vbeln2/posn2 above (SAP BSEG-VBEL2/POSN2, already documented as a "secondary/down-payment reference") may additionally carry the raw SAP-side down payment reference as BSEG mirror data — this column is the actual AIARAP-side applicative link, same role card_payment_id already plays for card charges.
    bank_debit_payment_id       UUID REFERENCES bank_debit_payment(id),  -- set only when source = 'aiarap' and the method is ACH/SEPA (ADR-0032); NULL otherwise. A late bank-side return flips THIS row's own status to 'reversed' — found via WHERE bank_debit_payment_id = :id — same reversal mechanism the doc's existing status CHECK already supports, no new derivation logic needed.
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
CREATE INDEX ON payment (sales_order_payment_id);
CREATE INDEX ON payment (bank_debit_payment_id);
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
-- pending_down_payment_amount (parking lot item 39, resolved): a
-- FI Down Payment (sales_order_payment, ADR-0029) posts against a
-- different reconciliation account (Advances from Customers, not Trade
-- Receivables) and isn't a normal open-AR item until cleared — so it's
-- surfaced here as ADDITIVE VISIBILITY only, never summed into
-- variance_amount, which stays purely about matching SAP Trade
-- Receivables against invoice.open_amount. A Payer checking their AIARAP
-- balance should see the true full picture — open Invoices AND any
-- pending Down Payment not yet applied — as two clearly separate numbers,
-- same "don't sum what genuinely can't be summed" discipline already
-- applied to cross-currency amounts in this domain.
CREATE TABLE ar_reconciliation_account (
    id                           UUID PRIMARY KEY DEFAULT uuidv7(),
    run_id                       UUID NOT NULL REFERENCES ar_reconciliation_run(id),
    payer_id                     UUID NOT NULL REFERENCES payer(id),
    company_code                 TEXT NOT NULL,
    currency                     TEXT NOT NULL REFERENCES currency(code),
    sap_open_amount              NUMERIC(18,2) NOT NULL,
    aiarap_open_amount           NUMERIC(18,2) NOT NULL,
    variance_amount              NUMERIC(18,2) NOT NULL,  -- sap_open_amount - aiarap_open_amount; 0 = clean
    pending_down_payment_amount  NUMERIC(18,2) NOT NULL DEFAULT 0,  -- SUM(sales_order_payment.amount WHERE clearing_status <> 'cleared') for this Payer/Company Code/currency, as of this run
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
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

-- Pending Down Payment summary (parking lot item 39, resolved) — kept
-- deliberately separate from every aging bucket above, including
-- "Current" (bucket_id NULL): a Down Payment (sales_order_payment not yet
-- cleared, ADR-0029) isn't an aged receivable at all, it's a credit
-- already collected and awaiting application to a future Invoice.
-- Blending it into any bucket would misrepresent it as something owed
-- rather than something already paid. Same "one row per Payer/Company
-- Code/currency per run" grain as ar_aging_snapshot_bucket, so the
-- dashboard shows it as a clearly separate summary line — a Payer
-- checking their AIARAP balance sees the true full picture, not just
-- open Invoices.
CREATE TABLE ar_aging_snapshot_down_payment (
    id                UUID PRIMARY KEY DEFAULT uuidv7(),
    snapshot_run_id   UUID NOT NULL REFERENCES ar_aging_snapshot_run(id),
    payer_id          UUID NOT NULL REFERENCES payer(id),
    company_code      TEXT NOT NULL,
    currency          TEXT NOT NULL REFERENCES currency(code),
    pending_amount    NUMERIC(18,2) NOT NULL,  -- SUM(sales_order_payment.amount WHERE clearing_status <> 'cleared') as of snapshot_date
    order_count       INTEGER NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        UUID,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by        UUID,
    CONSTRAINT ar_aging_snapshot_down_payment_company_code_fk
        FOREIGN KEY (payer_id, company_code)
        REFERENCES payer_company_code (payer_id, company_code),
    UNIQUE (snapshot_run_id, payer_id, company_code, currency)
);
CREATE INDEX ON ar_aging_snapshot_down_payment (payer_id, company_code, currency);
```

### Stripe payout reconciliation (ADR-0025)

```sql
-- Tenant-editable mapping from Stripe's raw balance_transaction.type enum
-- down into a small, fixed set of buckets a Tenant's finance team can
-- actually reason about. Seeded with sensible defaults (same "seeded,
-- then Tenant-editable" pattern as notification_template) — a Tenant can
-- remap a given Stripe type to a different bucket, but the bucket list
-- itself is fixed (the CHECK constraint on stripe_payout_transaction.bucket
-- below); the whole point is simplification, not letting the confusion
-- just move one level up into Tenant-invented bucket names. Full seed
-- mapping documented in ADR-0025 (parking lot item 29, resolved).
-- Scoped per Company Code, not flat per Tenant: GL accounts (below) are
-- genuinely Company-Code-specific in SAP (different legal entities have
-- different charts of accounts), and this table already lives alongside
-- everything else that moved to Company-Code grain once Stripe Connect
-- did (ADR-0020/0032) — same composite-key-over-surrogate-UUID convention
-- already used for shipping_priority/delivery_block_reason/
-- billing_block_reason.
-- debit_gl_account/credit_gl_account are REFERENCE DATA ONLY — which SAP
-- G/L accounts a Tenant's finance team would use for this bucket's
-- entries, shown on the reconciliation view for their own manual journal
-- entry — NOT an automated GL posting mechanism. "Automated GL posting to
-- SAP" is still explicitly Out of Scope for Phase 1 per the spec; adding
-- informational GL account fields here doesn't reverse that, since no job
-- reads these to actually post anything.
-- debit_posts_to_customer/credit_posts_to_customer: not every entry has a
-- fixed G/L account on both sides — real double-entry AR posting routes
-- one side to the transaction's own Customer/Payer reconciliation account
-- instead (SAP KNB1-AKONT-style), and WHICH side varies by bucket: a
-- 'charge' credits the Customer (reducing the receivable when payment
-- arrives), a 'refund' debits the Customer (reinstating it) — a 'fee' or
-- 'payout' bucket involves no Customer at all, both sides are fixed G/L
-- accounts. When a side's flag is true, that side's *_gl_account column
-- is left NULL — there's no fixed account to name, it's "post to whoever
-- the Customer on this transaction is," resolved at actual posting time
-- (were that ever built) from the Payer's own reconciliation account, not
-- a value stored here.
CREATE TABLE stripe_transaction_type_bucket (
    company_code              TEXT NOT NULL REFERENCES company_code(code),
    stripe_type                TEXT NOT NULL,  -- Stripe's raw balance_transaction.type value
    bucket                     TEXT NOT NULL
                               CHECK (bucket IN ('charge', 'refund', 'fee', 'reserve', 'payout', 'adjustment', 'transfer', 'other')),
    description                TEXT,
    debit_gl_account           TEXT,  -- reference only, see comment above; NULL when debit_posts_to_customer is true
    debit_posts_to_customer    BOOLEAN NOT NULL DEFAULT FALSE,
    credit_gl_account          TEXT,  -- reference only, see comment above; NULL when credit_posts_to_customer is true
    credit_posts_to_customer   BOOLEAN NOT NULL DEFAULT FALSE,
    status                     TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                 UUID,
    updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                 UUID,
    PRIMARY KEY (company_code, stripe_type),
    CONSTRAINT stripe_transaction_type_bucket_debit_side_chk
        CHECK (NOT (debit_posts_to_customer AND debit_gl_account IS NOT NULL)),
    CONSTRAINT stripe_transaction_type_bucket_credit_side_chk
        CHECK (NOT (credit_posts_to_customer AND credit_gl_account IS NOT NULL))
);

-- Stripe Payout header — the daily settlement Stripe pays to the Tenant's
-- bank account via their Connected Account (ADR-0020). company_code
-- (ADR-0020/0032 update) — a payout comes from exactly one Company
-- Code's own Connected Account, since Stripe Connect is one account per
-- Company Code, not per Tenant.
CREATE TABLE stripe_payout (
    id                 UUID PRIMARY KEY DEFAULT uuidv7(),
    company_code       TEXT NOT NULL REFERENCES company_code(code),
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
CREATE INDEX ON stripe_payout (company_code);
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
-- settlement currency). company_code (ADR-0020/0032 update) is
-- denormalized from stripe_payout — needed as its own column so
-- transaction_type's FK below can be a real composite reference into
-- stripe_transaction_type_bucket, now that table is keyed
-- (company_code, stripe_type), not just stripe_type alone. If Stripe
-- introduces a new type not yet mapped for this Company Code, extraction
-- fails loudly (a mapping row needs adding) rather than silently landing
-- in an unrecognized/default bucket. bucket is a denormalized snapshot of
-- that mapping AT INGESTION TIME, not a live join — if a Tenant edits the
-- mapping later, past transactions keep showing the bucket they were
-- actually reported under, same "store what was actually true, not a
-- live-recomputed value" reasoning used for notification.subject/body.
CREATE TABLE stripe_payout_transaction (
    id                       UUID PRIMARY KEY DEFAULT uuidv7(),
    payout_id                UUID NOT NULL REFERENCES stripe_payout(id),
    company_code             TEXT NOT NULL REFERENCES company_code(code),
    stripe_balance_txn_id    TEXT NOT NULL UNIQUE,  -- Stripe Balance Transaction ID (txn_xxx)
    stripe_charge_ref        TEXT,  -- Stripe Charge/PaymentIntent ID — the match key against card_payment.provider_charge_ref; NULL for pure fee/adjustment lines with no underlying charge
    transaction_type         TEXT NOT NULL,  -- Stripe's raw type, e.g. 'charge', 'network_cost', 'reserve_transaction'; composite-FKs into stripe_transaction_type_bucket below, scoped by this same company_code
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
    updated_by               UUID,
    CONSTRAINT stripe_payout_transaction_type_fk
        FOREIGN KEY (company_code, transaction_type)
        REFERENCES stripe_transaction_type_bucket (company_code, stripe_type)
);
CREATE INDEX ON stripe_payout_transaction (payout_id);
CREATE INDEX ON stripe_payout_transaction (company_code);
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

### Product Catalog (ADR-0029)

Deferred out of Tenancy & Identity (see that domain's naming/pattern notes) into Core AR/AP, since Product is a catalog/transactional entity, not an identity/tenancy one. Now that Sales Order pricing/tax is resolved entirely by a live SAP call at checkout (ADR-0029) rather than anything computed or stored locally, Product's own job is narrower than a full Material Master mirror: enough identifying data to build that live SAP request (a real Material Number, always) plus catalog display data (description, images, UOM).

```sql
-- SAP MARA/MAKT-equivalent (Material General Data + basic Description).
-- SAP-only sourcing (sap_material_id NOT NULL), unlike Payer/Invoice's
-- dual-source treatment — every product must tie back to a real SAP
-- Material Master, since ADR-0029's checkout flow calls SAP to create a
-- real Sales Order against it, which requires a real Material Number.
-- Only the DISPLAY layer (description_override, images below) can be
-- Tenant-supplied on top of the SAP-sourced record — there is no
-- fully-manual, no-SAP-tie product for Phase 1 (that option was
-- considered and rejected: see this session's discussion).
-- division is a MARA-level attribute (SAP SPART) — one Division per
-- Material — deliberately NOT part of product_sales_org's key below,
-- unlike payer_sales_area's 3-part Sales Area key. This mirrors real SAP:
-- MVKE (Material Sales Data) is keyed by Sales Org + Distribution Channel
-- only; Division lives on MARA, not on the sales-org-specific table.
CREATE TABLE product (
    id                    UUID PRIMARY KEY DEFAULT uuidv7(),
    sap_material_id       TEXT NOT NULL UNIQUE,  -- SAP MARA-MATNR
    description           TEXT NOT NULL,          -- SAP MAKT-MAKTX (base/SAP short text)
    description_override  TEXT,                   -- Tenant-editable portal-friendly text; NULL = display `description` as-is
    base_uom              TEXT NOT NULL,           -- SAP MARA-MEINS; plain TEXT, consistent with invoice_line.uom elsewhere in this doc
    material_type         TEXT,                    -- SAP MARA-MTART
    material_group        TEXT,                    -- SAP MARA-MATKL, useful for catalog categorization/filtering
    division              TEXT,                    -- SAP MARA-SPART
    ean_upc               TEXT,                    -- SAP MARA-EAN11
    status                TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag         BOOLEAN NOT NULL DEFAULT FALSE,  -- SAP LOEVM-equivalent (MARA-LVORM)
    custom_fields         JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            UUID,
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by            UUID
);

-- SAP MVKE-equivalent (Material Sales Data), keyed by Sales Org +
-- Distribution Channel only (real MVKE grain — no Division component,
-- see product's division column above). Drives catalog listing per Payer's
-- own Sales Area (this session's decision: catalog is Sales-Org-scoped,
-- not global) — a Payer only sees products with a row here matching their
-- own payer_sales_area (sales_org, distribution_channel), not blocked.
-- delivering_plant mirrors MVKE-DWERK; the assignment itself is validated
-- against sales_org_distribution_channel_plant (TVKWZ-equivalent) at the
-- application layer, not a DB-level composite FK, since that table's key
-- includes distribution_channel as plain TEXT (not promoted to a real
-- reference table this session) the same way this one does.
-- list_price/list_price_currency/list_price_extracted_at: an INDICATIVE
-- price for catalog browsing only, extracted periodically (new List Price
-- Extraction job, 0002-scheduled-jobs.md) from SAP condition records —
-- same "extracted per Tenant, not live-called" pattern as Currency
-- Exchange Rate/Invoice Type Extraction. This is deliberately NOT the
-- authoritative price: pricing itself is never computed or stored ahead
-- of time for real (ADR-0029) — the real price a Payer actually pays
-- always comes from the live BAPI_SALESORDER_SIMULATE call once a
-- product is added to a cart and simulated, and can legitimately differ
-- (scale discounts, promotions, tax). This is the general, Sales-Area-
-- level price; product_payer_price below is a more specific
-- Customer-level override, checked first when it exists.
-- No scale/quantity-break pricing modeled here — deliberately kept to one
-- flat number, not the RFQ domain's scale-pricing child-table pattern
-- (RFQ response line + price-break tiers). Any quantity-based break SAP
-- itself would apply is invisible to this flat indicative price and only
-- shows up once the live simulation actually runs against the cart's real
-- quantity — same as scale discounts generally, per the note above.
CREATE TABLE product_sales_org (
    id                       UUID PRIMARY KEY DEFAULT uuidv7(),
    product_id               UUID NOT NULL REFERENCES product(id),
    sales_org                TEXT NOT NULL REFERENCES sales_org(code),
    distribution_channel     TEXT NOT NULL,
    delivering_plant         TEXT REFERENCES plant(code),  -- SAP MVKE-DWERK
    sales_unit               TEXT,  -- SAP MVKE-VRKME; NULL = defaults to product.base_uom
    list_price               NUMERIC(18,4),
    list_price_currency      TEXT REFERENCES currency(code),
    list_price_extracted_at  TIMESTAMPTZ,
    blocked                  BOOLEAN NOT NULL DEFAULT FALSE,  -- simplified from SAP's richer Sales Status code set (unrestricted/phase-out/blocked) to a boolean + reason, same simplification already applied to payer_sales_area.billing_block
    blocked_reason           TEXT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by               UUID,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by               UUID,
    UNIQUE (product_id, sales_org, distribution_channel)
);
CREATE INDEX ON product_sales_org (product_id);
CREATE INDEX ON product_sales_org (sales_org, distribution_channel);  -- drives the Sales-Org-scoped catalog listing query
CREATE INDEX ON product_sales_org (delivering_plant);

-- Customer-specific list price override (SAP Customer-Material Info
-- Record/customer-specific condition record-equivalent) — more specific
-- than product_sales_org.list_price above, checked FIRST when a row
-- exists for this Payer, falling back to the Sales-Area-level price
-- otherwise. Same "extracted periodically, indicative only" treatment —
-- the real, final price is still always the live simulation call at
-- cart/checkout time, regardless of which indicative price was shown
-- while browsing. Scoped by the same (sales_org, distribution_channel)
-- as product_sales_org, since SAP pricing is generally Sales-Area-
-- dependent even at the customer-specific level — composite-FK'd into
-- product_sales_org to ensure a payer-specific price can't exist for a
-- Sales Area the product isn't even listed in.
CREATE TABLE product_payer_price (
    id                       UUID PRIMARY KEY DEFAULT uuidv7(),
    product_id               UUID NOT NULL REFERENCES product(id),
    payer_id                 UUID NOT NULL REFERENCES payer(id),
    sales_org                TEXT NOT NULL REFERENCES sales_org(code),
    distribution_channel     TEXT NOT NULL,
    list_price               NUMERIC(18,4) NOT NULL,
    list_price_currency      TEXT NOT NULL REFERENCES currency(code),
    list_price_extracted_at  TIMESTAMPTZ NOT NULL,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by               UUID,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by               UUID,
    UNIQUE (product_id, payer_id, sales_org, distribution_channel),
    CONSTRAINT product_payer_price_product_sales_org_fk
        FOREIGN KEY (product_id, sales_org, distribution_channel)
        REFERENCES product_sales_org (product_id, sales_org, distribution_channel)
);
CREATE INDEX ON product_payer_price (product_id, payer_id);
CREATE INDEX ON product_payer_price (payer_id);

-- SAP MARM-equivalent (Units of Measure for Material) — the alternative
-- UOMs a product can be ordered in beyond its base_uom, with the
-- conversion factor back to base_uom. product.base_uom itself is always
-- implicitly a valid order unit (1:1, matching real SAP: MARM only stores
-- ALTERNATIVE units, never the base unit as a row against itself) — this
-- table exists purely to let the Sales Order checkout flow (ADR-0029)
-- offer a UOM picker (e.g. order by EA or by BOX) rather than forcing
-- every order line into the base unit. numerator/denominator mirrors SAP
-- MARM-UMREZ/UMREN: 1 uom = (numerator / denominator) base_uom — e.g. a
-- BOX with numerator=12, denominator=1 means 1 BOX = 12 EA. ean_upc here
-- is per-UOM (SAP MARM-EAN11, e.g. a distinct barcode per packaging
-- level), more granular than product.ean_upc, which stays the base
-- unit's own EAN (SAP MARA-EAN11) — both are real, independently-
-- maintained SAP fields, not a duplicate of the same data. The actual
-- order-line quantity/UOM sent to SAP at checkout is still validated and
-- converted by SAP itself at Sales Order posting time (SAP is the
-- authority on MARM, this table is a local catalog-display copy) — this
-- table only needs to be accurate enough to populate the picker and any
-- local quantity/price display math.
CREATE TABLE product_uom (
    id             UUID PRIMARY KEY DEFAULT uuidv7(),
    product_id     UUID NOT NULL REFERENCES product(id),
    uom            TEXT NOT NULL,            -- SAP MARM-MEINH
    numerator      NUMERIC(13,3) NOT NULL,   -- SAP MARM-UMREZ
    denominator    NUMERIC(13,3) NOT NULL,   -- SAP MARM-UMREN
    ean_upc        TEXT,                     -- SAP MARM-EAN11, specific to this UOM
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by     UUID,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by     UUID,
    UNIQUE (product_id, uom)
);
CREATE INDEX ON product_uom (product_id);

-- Tenant-uploaded product images ONLY. SAP-sourced images/drawings (when a
-- Tenant maintains them in SAP DMS) are fetched LIVE at display time via
-- the SAP DMS integration, keyed off product.sap_material_id — same
-- on-demand-not-cached treatment as Invoice PDF (spec: "fetched live/
-- on-demand from SAP for both preview and download — not pre-cached at
-- extraction time"). There is nothing to persist for that case, so this
-- table has no source/discriminator column — every row here is a Tenant
-- upload, full stop.
CREATE TABLE product_image (
    id             UUID PRIMARY KEY DEFAULT uuidv7(),
    product_id     UUID NOT NULL REFERENCES product(id),
    storage_key    TEXT NOT NULL,  -- e.g. S3 object key
    caption        TEXT,
    display_order  INTEGER NOT NULL DEFAULT 0,
    is_primary     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by     UUID,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by     UUID
);
CREATE INDEX ON product_image (product_id);
-- at most one active primary image per product; same convention as tenant_contact/payer_payment_card
CREATE UNIQUE INDEX ON product_image (product_id) WHERE is_primary;
```

### Sales Order Checkout (ADR-0029)

SAP VBAK-equivalent (Sales Order header), shaped around the checkout flow's actual lifecycle rather than a full VBAK mirror — pricing/tax is never computed or stored ahead of time, only captured as the result of the live SAP simulation call, and the header tracks the checkout state machine (draft → priced → paid → created in SAP, or failed at any of those steps) alongside the identifying fields SAP itself needs.

```sql
-- Tenant-configurable shipping priority options (e.g. Standard/Expedited/
-- Overnight), scoped per Sales Org rather than flat per Tenant — a Tenant
-- can offer different shipping options in different Sales Orgs. Tenant
-- scoping itself is implicit (this table lives inside the {tenant} schema,
-- same as invoice_type/notification_template), sales_org narrows it
-- further. Natural composite key, matching the convention already used
-- for company_code/sales_org/plant/purchase_org rather than a surrogate
-- UUID for pure reference data.
CREATE TABLE shipping_priority (
    sales_org   TEXT NOT NULL REFERENCES sales_org(code),
    code        TEXT NOT NULL,  -- e.g. 'STD', 'EXP', 'OVN'
    name        TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by  UUID,
    PRIMARY KEY (sales_org, code)
);

-- SAP TVAK-equivalent (Sales Document Type customizing), extracted per
-- Tenant rather than seeded — same reasoning as invoice_type: SAP Sales
-- Document Types are customized per implementation (a Tenant may define
-- its own Z-order types), not a fixed platform-wide list.
CREATE TABLE sales_order_type (
    code        TEXT PRIMARY KEY,  -- SAP AUART, e.g. 'OR' (Standard Order), 'CS' (Cash Sale), or a Tenant's own custom Z-type
    name        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by  UUID
);

-- SAP TVLS-equivalent (Delivery Block Reasons), extracted per Tenant
-- rather than seeded — same reasoning as sales_order_type/invoice_type:
-- customized per SAP implementation. Scoped per Sales Order Type — a
-- Tenant may want a different available set of block reasons per Order
-- Type (e.g. 'CS' Cash Sale orders offering different reasons than 'OR'
-- Standard orders) — same composite-key-over-surrogate-UUID convention
-- already used for shipping_priority (scoped by sales_org).
CREATE TABLE delivery_block_reason (
    order_type  TEXT NOT NULL REFERENCES sales_order_type(code),
    code        TEXT NOT NULL,  -- SAP LIFSP
    name        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by  UUID,
    PRIMARY KEY (order_type, code)
);

-- SAP TVFS-equivalent (Billing Block Reasons), extracted per Tenant —
-- same reasoning and same Order-Type scoping as delivery_block_reason
-- above.
CREATE TABLE billing_block_reason (
    order_type  TEXT NOT NULL REFERENCES sales_order_type(code),
    code        TEXT NOT NULL,  -- SAP FAKSK
    name        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by  UUID,
    PRIMARY KEY (order_type, code)
);

-- sales_org/distribution_channel/division mirrors invoice's composite FK
-- into payer_sales_area — same reasoning: payer_sales_area is the local
-- source of truth for which Sales Areas exist for this Payer. company_code
-- likewise composite-FKs into payer_company_code, exactly like invoice.
-- payment_method (ADR-0029 update, extended by ADR-0032): 'credit_card',
-- 'ach', and 'sepa' all go through the same Stripe-charge-then-FI-Down-
-- Payment flow this table was originally designed around for cards alone
-- — ACH/SEPA reuse it as-is, since ADR-0032 already treats a Stripe
-- 'succeeded' event as sufficient to proceed, optimistically, the same
-- way a card charge does. 'purchase_order' (bill-on-account/net terms)
-- is the one method that skips payment entirely — gated by
-- payer_company_code.po_order_allowed (checked at the application layer,
-- not a DB constraint, same treatment as billing_block/credit_hold
-- elsewhere in this doc) — and goes straight from pricing_simulated to
-- SAP order creation, settling later as a normal open-AR Invoice under
-- payer_company_code.payment_terms, same as any Invoice that didn't
-- originate from this checkout flow. No sales_order_payment row exists
-- for a 'purchase_order' order — that table now covers the three
-- money-collecting methods, not 'credit_card' alone. Distinct from
-- customer_po_number below, which is just the buyer's own procurement
-- reference text and can be present regardless of payment_method.
-- fulfillment_hold_flagged_at/_reason (ADR-0032 update): an ACH/SEPA-
-- funded order's down payment can be returned DAYS after the SAP Sales
-- Order was already created and fulfillment may already be under way —
-- a materially higher-stakes situation than a plain Invoice payment
-- quietly reopening. A late return against this order's
-- sales_order_payment sets this flag (alongside the usual
-- payment.status = 'reversed' + AR Clerk notification, ADR-0032) so
-- whoever owns fulfillment on the Tenant side gets an explicit stop-ship
-- signal, not just an AR-side balance correction. Always NULL for
-- 'credit_card'/'purchase_order' orders — a card charge doesn't carry
-- this multi-day return risk, and a purchase_order order was never paid
-- at checkout in the first place. Most relevant to
-- 'submit_with_delivery_block' orders (below) where fulfillment could
-- genuinely already be moving; for 'hold_in_aiarap' orders a return
-- before SAP creation just cancels the order outright (status =
-- 'held_payment_returned') rather than needing a hold flag on a SAP
-- document that was never created.
-- delivery_block_code/delivery_block_cleared_at (ADR-0032 update):
-- mirrors SAP's own Delivery Block (VBAK-LIFSK, a reason-coded dropdown
-- via delivery_block_reason above, not a plain boolean — real SAP allows
-- multiple distinct block reasons, not just "blocked/not blocked") for
-- company_code.bank_debit_order_confirmation_mode =
-- 'submit_with_delivery_block' orders only — set at SAP creation time
-- (the order exists in SAP but can't generate a Delivery until cleared),
-- cleared (set back to NULL, delivery_block_cleared_at set) once
-- sales_order_payment.settlement_status reaches 'settled' and AIARAP
-- calls SAP to lift it. Always NULL for 'hold_in_aiarap' orders (nothing
-- to block — the order doesn't exist in SAP yet during the equivalent
-- risk window) and for 'credit_card'/'purchase_order' orders.
-- billing_block_code (SAP VBAK-FAKSK, same reason-coded dropdown
-- treatment via billing_block_reason) — general-purpose, not exclusively
-- tied to the ACH/SEPA flow (any Tenant user/AR Clerk can set it for any
-- reason), but also the natural pairing with delivery_block_code for a
-- 'submit_with_delivery_block' order — a Tenant may not want billing
-- generated either while payment is still unsettled, not just shipment.
-- Distinct from payer_sales_area.billing_block, which is a plain boolean
-- at the master-data level (blocks an entire Sales Area, not one order)
-- — real SAP's KNVV-FAKSD is genuinely just a flag, unlike VBAK-FAKSK.
-- status is the AIARAP-side checkout state machine, not an SAP status:
--   draft                    -- Payer still building the cart, no SAP call yet
--   pricing_simulated        -- live SAP pricing/tax simulation returned a quote
--   payment_failed           -- Stripe charge failed at checkout ('credit_card'/'ach'/'sepa' only — not reachable for 'purchase_order')
--   held_pending_settlement  -- ACH/SEPA only, mode = 'hold_in_aiarap': charge succeeded but SAP order creation is deliberately deferred until sales_order_payment.settlement_status reaches 'settled'
--   pending_sap_creation     -- charge succeeded ('credit_card' always; 'ach'/'sepa' immediately if mode = 'submit_with_delivery_block', or after leaving held_pending_settlement if mode = 'hold_in_aiarap'); 'purchase_order': approved to proceed with no charge — either way, the SAP order-creation call is in flight/retrying
--   sap_created              -- SAP Sales Order created successfully (sap_sales_order_id set); may still carry a delivery_block_code for 'submit_with_delivery_block' orders awaiting settlement
--   sap_creation_failed      -- retries exhausted; routed to the AR Clerk (ADR-0029's failure-handling decision) — for a money-collecting method this is after a successful charge, for 'purchase_order' there was never a charge to reverse
--   held_payment_returned    -- ACH/SEPA only, mode = 'hold_in_aiarap': the charge was returned/NSF while the order was held, before SAP ever created it — the held-order counterpart to a plain Invoice-payment reversal, but here there's no payment/Invoice to unwind since nothing downstream was ever created
--   cancelled                -- abandoned pre-payment (draft/pricing_simulated only — nothing to reverse)
-- 'sap_created' is the terminal success state for THIS table — matching
-- the eventual Invoice against sales_document = sap_sales_order_id, and
-- driving the FI Down Payment clearing ('credit_card' orders only), both
-- happen via sales_order_payment (a separate table, not yet designed this
-- pass).
-- Shipping/billing address override (moved to sales_order_partner below —
-- address_override_* columns there, scoped to only the ship_to/bill_to
-- partner functions).
-- shipping_priority_code composite-FKs into shipping_priority, scoped by
-- this order's own sales_org (a Sales Org's shipping priority list
-- shouldn't be selectable from a different Sales Org's order).
-- 3rd-party/collect-shipment carrier code + account number are
-- deliberately NOT dedicated columns — they live in custom_fields below
-- instead (per ADR-0003's generic custom-fields mechanism), same as any
-- other Tenant-specific extension AIARAP's core schema doesn't need to
-- model structurally.
CREATE TABLE sales_order (
    id                              UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id                        UUID NOT NULL REFERENCES payer(id),
    company_code                    TEXT NOT NULL REFERENCES company_code(code),
    sales_org                       TEXT NOT NULL REFERENCES sales_org(code),
    distribution_channel            TEXT NOT NULL,
    division                        TEXT NOT NULL,
    order_type                      TEXT NOT NULL REFERENCES sales_order_type(code),  -- SAP VBAK-AUART
    payment_method                  TEXT NOT NULL CHECK (payment_method IN ('credit_card', 'ach', 'sepa', 'purchase_order')),
    customer_po_number              TEXT,  -- SAP VBKD-BSTNK (Customer PO Number) — the Payer's own procurement reference, purely informational
    requested_delivery_date         DATE,  -- SAP VBAK-VDATU
    currency                        TEXT NOT NULL REFERENCES currency(code),  -- SAP VBAK-WAERK; set from the start (e.g. defaulted from payer_sales_area.currency) — also the currency the live pricing/tax quote below is returned in, no separate column needed for that
    incoterms_1                     TEXT,  -- SAP VBAK-INCO1, e.g. 'FOB', 'CIF' — same naming convention as payer_sales_area.incoterms_1
    incoterms_2                     TEXT,  -- SAP VBAK-INCO2, named place/location qualifying incoterms_1
    status                          TEXT NOT NULL DEFAULT 'draft'
                                    CHECK (status IN ('draft', 'pricing_simulated', 'payment_failed', 'held_pending_settlement', 'pending_sap_creation', 'sap_created', 'sap_creation_failed', 'held_payment_returned', 'cancelled')),
    sap_sales_order_id              TEXT,  -- SAP VBAK-VBELN; NULL until status = 'sap_created'
    priced_at                       TIMESTAMPTZ,  -- when the live SAP pricing/tax simulation call last returned
    net_amount                      NUMERIC(18,2),
    tax_amount                      NUMERIC(18,2),
    total_amount                    NUMERIC(18,2),  -- what the Payer is actually charged at checkout
    raw_pricing_simulation          JSONB,  -- full SAP simulation response, for checkout summary display and audit/troubleshooting — same "structured columns for what's queried, JSONB for the rest" pattern as payment_provider_webhook_event.payload
    sap_creation_status             TEXT NOT NULL DEFAULT 'pending'
                                    CHECK (sap_creation_status IN ('pending', 'posted', 'failed')),
    sap_creation_attempts           INTEGER NOT NULL DEFAULT 0,
    sap_creation_last_error         TEXT,
    ar_clerk_notified_at            TIMESTAMPTZ,  -- set when sap_creation_status reaches 'failed' after exhausting retries — routed to payer_company_code.accounting_clerk_user_id per ADR-0029
    fulfillment_hold_flagged_at     TIMESTAMPTZ,  -- ADR-0032: set on a late ACH/SEPA return against this order's sales_order_payment, after sap_created — a stop-ship signal for the Tenant's fulfillment owner, distinct from the AR-side payment.status='reversed' correction
    fulfillment_hold_reason          TEXT,
    delivery_block_code              TEXT,  -- SAP VBAK-LIFSK; NULL = not blocked. Set at SAP creation time for 'submit_with_delivery_block' orders, cleared (set back to NULL) once settlement confirmed. Composite-FKs into delivery_block_reason(order_type, code) below — scoped by THIS order's own order_type, same convention as shipping_priority_code's sales_org scoping
    delivery_block_cleared_at        TIMESTAMPTZ,
    billing_block_code               TEXT,  -- SAP VBAK-FAKSK; NULL = not blocked. Composite-FKs into billing_block_reason(order_type, code) below
    shipping_priority_code          TEXT,  -- SAP VBAK-LPRIO-equivalent
    custom_fields                   JSONB NOT NULL DEFAULT '{}'::jsonb,  -- carries 3rd-party carrier code + account number, among any other Tenant-specific extensions
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                      UUID,
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                      UUID,
    CONSTRAINT sales_order_company_code_fk
        FOREIGN KEY (payer_id, company_code)
        REFERENCES payer_company_code (payer_id, company_code),
    CONSTRAINT sales_order_sales_area_fk
        FOREIGN KEY (payer_id, sales_org, distribution_channel, division)
        REFERENCES payer_sales_area (payer_id, sales_org, distribution_channel, division),
    CONSTRAINT sales_order_shipping_priority_fk
        FOREIGN KEY (sales_org, shipping_priority_code)
        REFERENCES shipping_priority (sales_org, code),
    CONSTRAINT sales_order_delivery_block_fk
        FOREIGN KEY (order_type, delivery_block_code)
        REFERENCES delivery_block_reason (order_type, code),
    CONSTRAINT sales_order_billing_block_fk
        FOREIGN KEY (order_type, billing_block_code)
        REFERENCES billing_block_reason (order_type, code)
);
CREATE UNIQUE INDEX ON sales_order (sap_sales_order_id) WHERE sap_sales_order_id IS NOT NULL;
CREATE INDEX ON sales_order (order_type);
CREATE INDEX ON sales_order (payment_method);
CREATE INDEX ON sales_order (payer_id);
CREATE INDEX ON sales_order (payer_id, company_code);
CREATE INDEX ON sales_order (payer_id, sales_org, distribution_channel, division);
CREATE INDEX ON sales_order (status);
CREATE INDEX ON sales_order (sales_org, shipping_priority_code);
-- drives the checkout-failure sweep that retries SAP order creation
CREATE INDEX ON sales_order (sap_creation_status) WHERE sap_creation_status IN ('pending', 'failed');
-- drives the fulfillment-hold worklist for the Tenant's fulfillment owner
CREATE INDEX ON sales_order (fulfillment_hold_flagged_at) WHERE fulfillment_hold_flagged_at IS NOT NULL;
-- drives the Sales Order Bank-Debit Confirmation Batch's delivery-block-clearing sweep
CREATE INDEX ON sales_order (delivery_block_code) WHERE delivery_block_code IS NOT NULL;
CREATE INDEX ON sales_order (billing_block_code) WHERE billing_block_code IS NOT NULL;

-- SAP TPAR-equivalent (Partner Function customizing) — Tenant-editable,
-- seeded with the common defaults ('WE' Ship-to, 'RE' Bill-to, 'RG'
-- Payer/payer-of-invoice) but not hardcoded to just those; a Tenant can
-- define its own additional partner functions, same "Tenant-editable,
-- seeded with defaults" pattern as invoice_type/notification_template.
-- 'AG' (Sold-to) is deliberately NOT seeded here — sales_order.payer_id
-- already IS the Sold-to, so it stays implicit rather than duplicated as
-- a row in sales_order_partner below.
CREATE TABLE partner_function (
    code        TEXT PRIMARY KEY,  -- e.g. 'WE', 'RE', 'RG', or a Tenant's own custom code
    name        TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by  UUID
);

-- SAP VBPA-equivalent (Sales Order Partners) — fully configurable via
-- partner_function above, not hardcoded to Ship-to/Bill-to only. Sold-to
-- stays implicit (sales_order.payer_id itself, never a row here). Any
-- other partner function can each independently point at a DIFFERENT
-- Payer (e.g. a child customer under payer_hierarchy) than the ordering
-- Payer. Kept header-level, not per-line, for Phase 1 simplicity — SAP
-- itself supports item-level partner overrides, not modeled here.
-- partner_payer_id is not constrained by a DB check to be
-- hierarchy-related to sales_order.payer_id — validated at the
-- application layer against payer_hierarchy (time-sliced/sales-area-
-- scoped, not practical to express as a static FK/CHECK), same
-- "app-layer validation" treatment as payer_hierarchy's own
-- non-overlapping-date-range rule elsewhere in this doc.
-- address_override_*: a freeform, order-specific address override — NULL
-- = use this partner_payer_id's own registered Payer address; set = a
-- one-off different address (e.g. a job site) with no Payer/hierarchy
-- record of its own, distinct from picking a different Payer as the
-- partner. Deliberately restricted to the ship_to and bill_to functions
-- only (enforced by the CHECK constraint below) — a physical/billing
-- address override doesn't make sense for an arbitrary Tenant-defined
-- partner function the way it does for these two. Moved here from a flat
-- set of columns on sales_order itself — an address override
-- conceptually belongs to a specific partner, not the order header.
CREATE TABLE sales_order_partner (
    id                        UUID PRIMARY KEY DEFAULT uuidv7(),
    sales_order_id            UUID NOT NULL REFERENCES sales_order(id),
    partner_function          TEXT NOT NULL REFERENCES partner_function(code),
    partner_payer_id          UUID NOT NULL REFERENCES payer(id),
    address_override_line1    TEXT,
    address_override_line2    TEXT,
    address_override_city     TEXT,
    address_override_state    TEXT,
    address_override_postal   TEXT,
    address_override_country  TEXT,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                UUID,
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                UUID,
    UNIQUE (sales_order_id, partner_function),
    CONSTRAINT sales_order_partner_address_override_chk
        CHECK (
            partner_function IN ('ship_to', 'bill_to')
            OR (address_override_line1 IS NULL AND address_override_line2 IS NULL
                AND address_override_city IS NULL AND address_override_state IS NULL
                AND address_override_postal IS NULL AND address_override_country IS NULL)
        )
);
CREATE INDEX ON sales_order_partner (sales_order_id);
CREATE INDEX ON sales_order_partner (partner_function);
CREATE INDEX ON sales_order_partner (partner_payer_id);

-- SAP VBAP-equivalent (Sales Document Item). Shaped like invoice_line
-- (the analogous VBRP-equivalent) — unit_price/net_amount/tax_amount/
-- line_amount hold this line's share of the live SAP pricing/tax
-- simulation result (populated once sales_order.status reaches
-- 'pricing_simulated', NULL before that), with the header's own
-- net_amount/tax_amount/total_amount being the rollup across all lines,
-- same header/line split as invoice/invoice_line's total_amount vs. line
-- amounts. No account-assignment columns (profit_center/cost_center/etc.,
-- present on invoice_line) — unlike a Bill/Invoice line, a Payer
-- self-service checkout line has no such data to enter; SAP derives
-- account assignment itself from Material/Customer master at order
-- creation time, the same "SAP is the authority, AIARAP doesn't own the
-- derivation" principle already applied to pricing/tax.
-- uom stays plain TEXT, not a composite FK — a line can legally be either
-- product.base_uom (never a product_uom row, by that table's own design)
-- or a row in product_uom, and a single composite FK can't express an
-- "OR the base unit" condition; validated at the application layer
-- instead, same treatment product_uom's own comment already flags.
-- delivering_plant defaults from product_sales_org.delivering_plant at
-- line-creation time but can be overridden per line, matching real SAP
-- WERKS behavior (Sales Area context supplies a default, item-level can
-- still differ). Whether the chosen product is actually listed/not
-- blocked for this order's Sales Org/Distribution Channel
-- (product_sales_org) is an application-layer check, not a DB constraint
-- — sales_order itself carries sales_org/distribution_channel (not
-- duplicated here), and "blocked" is a value check a FK can't express
-- anyway, consistent with billing_block/credit_hold elsewhere in this doc.
CREATE TABLE sales_order_line (
    id                      UUID PRIMARY KEY DEFAULT uuidv7(),
    sales_order_id          UUID NOT NULL REFERENCES sales_order(id),
    line_number             INTEGER NOT NULL,
    product_id              UUID NOT NULL REFERENCES product(id),
    quantity                NUMERIC(15,3) NOT NULL,  -- SAP VBAP-KWMENG
    uom                     TEXT NOT NULL,  -- the Payer-selected order unit
    requested_delivery_date  DATE,  -- SAP VBEP-EDATU-equivalent input (the requested date, as entered — distinct from sales_order_schedule_line.confirmed_delivery_date, which is SAP's own ATP-confirmed output). Defaults from sales_order.requested_delivery_date at line-creation time, but the Payer can override it per line before simulating
    delivering_plant        TEXT REFERENCES plant(code),  -- SAP VBAP-WERKS
    unit_price              NUMERIC(18,4),   -- from the live SAP pricing simulation; NULL until sales_order.status reaches 'pricing_simulated'
    net_amount              NUMERIC(18,2),
    tax_amount              NUMERIC(18,2),
    line_amount             NUMERIC(18,2),   -- net + tax; sums to sales_order.total_amount across all lines
    currency                TEXT REFERENCES currency(code),  -- mirrors the header's currency; carried here too, same convention as invoice_line.currency alongside invoice.currency
    custom_fields           JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              UUID,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by              UUID,
    UNIQUE (sales_order_id, line_number)
);
CREATE INDEX ON sales_order_line (sales_order_id);
CREATE INDEX ON sales_order_line (product_id);
CREATE INDEX ON sales_order_line (delivering_plant);

-- SAP VBEP-equivalent (Schedule Lines) — display-only, populated entirely
-- from the live SAP pricing/tax simulation call (ADR-0029), the same one
-- that fills sales_order_line.unit_price/net_amount/tax_amount/
-- line_amount. When availability/ATP splits a line's ordered quantity
-- across multiple confirmed delivery dates (e.g. partial stock now, the
-- remainder later), SAP returns one schedule line per split — AIARAP
-- stores and shows them as-is, never creates/edits one itself. No
-- write path back to SAP exists for this table, consistent with "SAP is
-- the authority, AIARAP doesn't own the derivation" already applied to
-- pricing/tax/account-assignment elsewhere in the Sales Order Checkout
-- domain. Re-simulating the order (e.g. the Payer changes the cart)
-- replaces a line's schedule lines wholesale rather than updating them in
-- place — an insert-only snapshot of the simulation's own result, same
-- "immutable point-in-time record" treatment as card_payment_attempt
-- (no updated_at/updated_by, since nothing about a row changes after
-- insert; a re-simulation deletes and reinserts instead).
CREATE TABLE sales_order_schedule_line (
    id                        UUID PRIMARY KEY DEFAULT uuidv7(),
    sales_order_line_id      UUID NOT NULL REFERENCES sales_order_line(id),
    schedule_line_number      INTEGER NOT NULL,  -- SAP VBEP-ETENR
    confirmed_quantity        NUMERIC(15,3) NOT NULL,  -- SAP VBEP-BMENG
    confirmed_delivery_date   DATE,  -- SAP VBEP-EDATU
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                UUID,
    UNIQUE (sales_order_line_id, schedule_line_number)
);
CREATE INDEX ON sales_order_schedule_line (sales_order_line_id);

-- Tracks the checkout-time charge collected BEFORE any Invoice exists,
-- and the FI Down Payment it gets posted to SAP as (ADR-0029) — every
-- money-collecting payment_method ('credit_card', 'ach', 'sepa', per
-- ADR-0032's extension); a 'purchase_order' order never creates a row
-- here (see sales_order's payment_method comment). Same "detail table
-- for the AIARAP/Stripe-specific mechanics" role card_payment/
-- bank_debit_payment already play for Invoice-time charges, one step
-- earlier in the lifecycle (no invoice_id to attach to yet at this
-- point).
-- payment_method distinguishes which of the three applies, since ACH/SEPA
-- carry the multi-day settlement_status/return_code tracking
-- bank_debit_payment already has and 'credit_card' doesn't need it
-- (always NULL for 'credit_card' rows, same nullable-when-not-applicable
-- treatment used elsewhere in this doc).
-- sap_posting_status/attempts/last_error mirrors card_payment's own SAP
-- write-back retry shape. sap_reference_written is the value AIARAP writes
-- into the FI Down Payment's own reference/assignment field (SAP
-- BSEG-ZUONR/XREF1) at posting time — always sales_order.sap_sales_order_id
-- — which is what lets AIARAP (not a clerk) later drive the clearing match
-- precisely, avoiding FI Down Payment's real-world misapplication risk
-- (ADR-0029's core reasoning for choosing FI over SD). clearing_status
-- tracks that later step: 'pending' until AIARAP matches the eventual
-- Invoice (via invoice_line.sales_document = sales_order.sap_sales_order_id)
-- and drives/verifies the down payment clearing itself; 'cleared' once
-- done, with matched_invoice_id set and a normal payment row created
-- against that Invoice (payment.sales_order_payment_id points back here,
-- same role payment.card_payment_id already plays) so
-- invoice.open_amount's derivation keeps working uniformly regardless of
-- source; 'mismatch_flagged' if AIARAP's own automated clearing attempt
-- doesn't reconcile cleanly (e.g. SAP's own auto-clearing already applied
-- it elsewhere before AIARAP's check ran) — surfaced for manual
-- investigation rather than silently retried.
-- A late ACH/SEPA return against a row here (settlement_status =
-- 'returned') doesn't just flip the resulting payment row to 'reversed'
-- the way a direct Invoice-payment return does (ADR-0032's base case) —
-- it ALSO sets sales_order.fulfillment_hold_flagged_at, since by this
-- point the SAP Sales Order may already be created and fulfillment
-- already under way, a materially higher-stakes situation than an
-- Invoice quietly reopening.
CREATE TABLE sales_order_payment (
    id                              UUID PRIMARY KEY DEFAULT uuidv7(),
    sales_order_id                  UUID NOT NULL REFERENCES sales_order(id),
    payer_id                        UUID NOT NULL REFERENCES payer(id),
    payment_method                  TEXT NOT NULL CHECK (payment_method IN ('credit_card', 'ach', 'sepa')),
    amount                          NUMERIC(18,2) NOT NULL,
    currency                        TEXT NOT NULL REFERENCES currency(code),
    provider                        TEXT NOT NULL DEFAULT 'stripe',
    provider_charge_ref              TEXT NOT NULL,  -- e.g. Stripe PaymentIntent/Charge ID
    charged_at                      TIMESTAMPTZ NOT NULL,
    settlement_status               TEXT CHECK (settlement_status IN ('pending', 'settled', 'returned')),  -- ACH/SEPA only (ADR-0032); NULL for 'credit_card'
    settled_at                      TIMESTAMPTZ,  -- ACH/SEPA only
    returned_at                     TIMESTAMPTZ,  -- ACH/SEPA only
    return_code                     TEXT,  -- ACH/SEPA only — same return-code shape as bank_debit_payment.return_code
    return_reason                    TEXT,  -- ACH/SEPA only
    sap_down_payment_document       TEXT,  -- SAP FI special-G/L document number, once posted
    sap_down_payment_document_year  TEXT,  -- pairs with sap_down_payment_document, same fiscal-year-scoping reasoning as invoice.fi_document_year
    sap_reference_written           TEXT,  -- value written into the down payment's own BSEG-ZUONR/XREF1 — always sales_order.sap_sales_order_id
    sap_posting_status              TEXT NOT NULL DEFAULT 'pending'
                                    CHECK (sap_posting_status IN ('pending', 'posted', 'failed')),
    sap_posting_attempts            INTEGER NOT NULL DEFAULT 0,
    sap_posting_last_error          TEXT,
    clearing_status                 TEXT NOT NULL DEFAULT 'pending'
                                    CHECK (clearing_status IN ('pending', 'cleared', 'mismatch_flagged')),
    cleared_at                      TIMESTAMPTZ,
    matched_invoice_id              UUID REFERENCES invoice(id),  -- set once clearing_status = 'cleared'
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                      UUID,
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                      UUID,
    UNIQUE (provider, provider_charge_ref)
);
CREATE INDEX ON sales_order_payment (sales_order_id);
CREATE INDEX ON sales_order_payment (payer_id);
CREATE INDEX ON sales_order_payment (matched_invoice_id);
-- drives the SAP down payment posting retry sweep
CREATE INDEX ON sales_order_payment (sap_posting_status) WHERE sap_posting_status IN ('pending', 'failed');
-- drives the clearing-match sweep against newly-extracted Invoices
CREATE INDEX ON sales_order_payment (clearing_status) WHERE clearing_status = 'pending';
```

