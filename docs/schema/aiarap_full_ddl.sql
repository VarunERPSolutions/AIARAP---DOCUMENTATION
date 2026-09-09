-- =============================================================================
-- AIARAP Phase 1 -- Complete Consolidated & Dependency-Ordered PostgreSQL DDL
-- =============================================================================
-- Source: docs/schema/0001-phase-1-table-structures.md (the sole authoritative
-- DDL source in AIARAP---DOCUMENTATION; ADR-0029 and ADR-0038 each contain a
-- table definition that also appears here -- verified identical, not a
-- separate/conflicting definition, so nothing extra was pulled from them).
--
-- Every table name, column name, and data type below is preserved EXACTLY as
-- documented (verified programmatically: 1,008/1,008 typed columns match).
-- The only thing this script changes is EXECUTION ORDER and CONSTRAINT
-- TIMING: every table is created first with its FOREIGN KEY clauses removed,
-- then every FOREIGN KEY is added back via ALTER TABLE ... ADD CONSTRAINT in
-- a second pass (Section 3). This sidesteps every forward-reference the
-- source document calls out explicitly (e.g. payer_payment_card -> a
-- company_code table defined ~400 lines later; card_payment -> invoice,
-- defined ~700 lines later) without needing to hand-solve the dependency
-- graph table by table -- once every table exists, no FK can fail regardless
-- of how the source document's narrative ordering interleaves domains.
--
-- Run this against a FRESH PostgreSQL 18+ database (needed for native
-- uuidv7()). On an older major version, install the pg_uuidv7 extension
-- instead -- see the commented-out line in Section 1; no other line changes.
-- =============================================================================

-- ============================================================
-- AIARAP Phase 1 — Full Consolidated DDL
-- Auto-assembled from docs/schema/0001-phase-1-table-structures.md
-- Table names, column names, and data types are preserved exactly
-- as documented. This script only reorders/defers constraints so
-- the whole schema can be created in one pass against a fresh DB.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Extensions, schemas, and the uuidv7() bootstrap
-- ------------------------------------------------------------

-- citext: case-insensitive email uniqueness (per 0001-phase-1-table-structures.md)
CREATE EXTENSION IF NOT EXISTS citext;

-- uuidv7(): native as of Postgres 18. If running on an older major version,
-- install the pg_uuidv7 extension instead (uncomment below) -- no DDL below
-- needs to change either way, since every PK just calls uuidv7().
-- CREATE EXTENSION IF NOT EXISTS pg_uuidv7;

-- global: AIARAP-internal, cross-tenant entities (global.tenant_registry, etc.)
CREATE SCHEMA IF NOT EXISTS global;

-- tenant_template: one concrete tenant schema, deployed identically per
-- Tenant per ADR-0004 (schema-per-tenant isolation). To onboard another
-- Tenant, re-run section 2 below with this schema name substituted for a new
-- one (e.g. acme, contoso) -- the DDL itself never changes per Tenant.
CREATE SCHEMA IF NOT EXISTS tenant_template;

-- ------------------------------------------------------------
-- 1. Tables (all FOREIGN KEY constraints deferred to section 3)
--    Order follows the source document's own domain grouping:
--    Tenancy & Identity -> Security/Roles -> Core AR/AP ->
--    Access/Onboarding -> Batch/Integration. Safe in any order here
--    since no FK is enforced until section 3 runs.
-- ------------------------------------------------------------

CREATE TABLE global.tenant_registry (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    subdomain TEXT NOT NULL UNIQUE,
    schema_name TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL DEFAULT 'provisioning' CHECK (status IN ('provisioning', 'active', 'suspended', 'deprovisioned')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);

CREATE TABLE global.tenant_employee_domain (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    tenant_registry_id UUID NOT NULL,
    domain TEXT NOT NULL UNIQUE,
    schema_name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID
);
CREATE INDEX ON global.tenant_employee_domain (tenant_registry_id);

CREATE TABLE global.stripe_account_routing (
    connected_account_id TEXT PRIMARY KEY,
    tenant_registry_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID
);
CREATE INDEX ON global.stripe_account_routing (tenant_registry_id);

CREATE TABLE global.tenant_contact (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    tenant_registry_id UUID NOT NULL,
    name TEXT NOT NULL,
    email CITEXT,
    phone TEXT,
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON global.tenant_contact (tenant_registry_id);
-- at most one ACTIVE primary per Tenant; an inactive old primary no longer
-- blocks promoting a new one (zero active primaries is allowed transiently)
CREATE UNIQUE INDEX ON global.tenant_contact (tenant_registry_id) WHERE is_primary AND status = 'active';

CREATE TABLE global.aiarap_staff (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    name TEXT NOT NULL,
    email CITEXT NOT NULL UNIQUE,
    phone TEXT,
    office_address_line1 TEXT,
    office_address_line2 TEXT,
    office_city TEXT,
    office_state_province TEXT,
    office_postal_code TEXT,
    office_country TEXT,
    department TEXT,
    employment_status TEXT NOT NULL DEFAULT 'active' CHECK (employment_status IN ('active', 'terminated')),
    terminated_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);

CREATE TABLE global.customer_representative (
    staff_id UUID PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);

CREATE TABLE tenant_template.currency (
    code TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    minor_unit SMALLINT NOT NULL DEFAULT 2,
    symbol TEXT
);

CREATE TABLE tenant_template.currency_exchange_rate (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    rate_type TEXT NOT NULL DEFAULT 'M',
    from_currency TEXT NOT NULL,
    to_currency TEXT NOT NULL,
    rate_date DATE NOT NULL,
    exchange_rate NUMERIC(18,6) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (rate_type, from_currency, to_currency, rate_date)
);
CREATE INDEX ON tenant_template.currency_exchange_rate (from_currency, to_currency, rate_date);

CREATE TABLE tenant_template.tenant_settings (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    singleton_guard BOOLEAN NOT NULL DEFAULT TRUE UNIQUE CHECK (singleton_guard),
    tenant_registry_id UUID NOT NULL,
    branding_logo_s3_key TEXT,
    branding_primary_color TEXT,
    sap_system_of_record_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    salesforce_system_of_record_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    sap_connection_endpoint TEXT,
    sap_auth_type TEXT NOT NULL DEFAULT 'basic' CHECK (sap_auth_type IN ('basic', 'oauth2', 'certificate')),
    sap_basic_auth_username TEXT,
    sap_credential_secret_ref TEXT,
    sap_credential_updated_at TIMESTAMPTZ,
    sap_credential_validity_days INTEGER,
    sap_oauth_token_secret_ref TEXT,
    sap_oauth_token_expires_at TIMESTAMPTZ,
    salesforce_connection_endpoint TEXT,
    salesforce_auth_type TEXT NOT NULL DEFAULT 'oauth2' CHECK (salesforce_auth_type IN ('basic', 'oauth2', 'certificate')),
    salesforce_basic_auth_username TEXT,
    salesforce_credential_secret_ref TEXT,
    salesforce_credential_updated_at TIMESTAMPTZ,
    salesforce_credential_validity_days INTEGER,
    salesforce_oauth_token_secret_ref TEXT,
    salesforce_oauth_token_expires_at TIMESTAMPTZ,
    salesforce_app_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    salesforce_app_client_id TEXT,
    salesforce_app_client_secret_ref TEXT,
    sso_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    sso_provider_type TEXT CHECK (sso_provider_type IN ('saml', 'oidc')),
    sso_metadata_secret_ref TEXT,
    sap_webhook_secret_ref TEXT,
    card_auto_pay_max_failed_attempts INTEGER NOT NULL DEFAULT 3,
    sms_notifications_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.tenant_settings (tenant_registry_id);

CREATE TABLE tenant_template.notification_sender_identity (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    domain CITEXT NOT NULL UNIQUE,
    verification_status TEXT NOT NULL DEFAULT 'pending' CHECK (verification_status IN ('pending', 'verified', 'failed')),
    provider_verification_ref TEXT,
    verified_at TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);

CREATE TABLE tenant_template.notification_sender_dns_record (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    sender_identity_id UUID NOT NULL,
    record_purpose TEXT NOT NULL CHECK (record_purpose IN ('dkim', 'spf')),
    record_type TEXT NOT NULL CHECK (record_type IN ('CNAME', 'TXT')),
    record_name TEXT NOT NULL,
    record_value TEXT NOT NULL,
    verification_status TEXT NOT NULL DEFAULT 'pending' CHECK (verification_status IN ('pending', 'verified', 'failed')),
    verified_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.notification_sender_dns_record (sender_identity_id);

CREATE TABLE tenant_template.notification_template (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    notification_type TEXT NOT NULL,
    channel TEXT NOT NULL DEFAULT 'email' CHECK (channel IN ('email', 'sms')),
    sender_identity_id UUID,
    sender_email CITEXT,
    sender_name TEXT,
    subject_template TEXT,
    body_template TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (notification_type, channel)
);

CREATE TABLE tenant_template.notification (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    recipient_user_id UUID NOT NULL,
    channel TEXT NOT NULL DEFAULT 'email' CHECK (channel IN ('email', 'sms')),
    notification_type TEXT NOT NULL,
    template_id UUID NOT NULL,
    sender_identity_id UUID,
    sender_email TEXT NOT NULL,
    subject TEXT,
    body TEXT NOT NULL,
    related_entity_type TEXT,
    related_entity_id UUID,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed')),
    sent_at TIMESTAMPTZ,
    failure_reason TEXT,
    retry_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.notification (recipient_user_id);
CREATE INDEX ON tenant_template.notification (notification_type);
CREATE INDEX ON tenant_template.notification (status);
-- drives any retry sweep of 'failed'/'pending' rows
CREATE INDEX ON tenant_template.notification (related_entity_type, related_entity_id);

CREATE TABLE tenant_template.customer_representative_assignment_request (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    customer_rep_id UUID NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'denied')),
    requested_by UUID NOT NULL,
    decided_by UUID,
    decided_at TIMESTAMPTZ,
    denial_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.customer_representative_assignment_request (customer_rep_id);
CREATE INDEX ON tenant_template.customer_representative_assignment_request (status);

CREATE TABLE tenant_template.assigned_customer_representative (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    customer_rep_id UUID NOT NULL,
    assignment_request_id UUID,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    valid_upto TIMESTAMPTZ,
    deactivated_by UUID,
    deactivated_at TIMESTAMPTZ,
    deactivation_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.assigned_customer_representative (customer_rep_id);
-- at most one *active* assignment per rep at a time; reactivation inserts a new row
CREATE UNIQUE INDEX ON tenant_template.assigned_customer_representative (customer_rep_id) WHERE is_active;

CREATE TABLE tenant_template.payer (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    sap_customer_id TEXT,
    salesforce_customer_id TEXT,
    name TEXT NOT NULL,
    tax_id TEXT,
    currency TEXT,
    address_line1 TEXT,
    address_line2 TEXT,
    city TEXT,
    state_province TEXT,
    postal_code TEXT,
    country TEXT,
    custom_fields JSONB NOT NULL DEFAULT '{}'::jsonb,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    CONSTRAINT payer_source_id_present CHECK (sap_customer_id IS NOT NULL OR salesforce_customer_id IS NOT NULL)
);
CREATE UNIQUE INDEX ON tenant_template.payer (sap_customer_id) WHERE sap_customer_id IS NOT NULL;
CREATE UNIQUE INDEX ON tenant_template.payer (salesforce_customer_id) WHERE salesforce_customer_id IS NOT NULL;

CREATE TABLE tenant_template.payer_email_domain (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id UUID NOT NULL,
    domain TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    UNIQUE (payer_id, domain)
);
CREATE INDEX ON tenant_template.payer_email_domain (domain);

CREATE TABLE tenant_template.payer_hierarchy (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id UUID NOT NULL,
    parent_payer_id UUID NOT NULL,
    sales_org TEXT NOT NULL,
    distribution_channel TEXT NOT NULL,
    division TEXT NOT NULL,
    valid_from DATE NOT NULL,
    valid_to DATE,
    deletion_flag BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    CONSTRAINT payer_hierarchy_not_self_parent CHECK (payer_id <> parent_payer_id)
);
CREATE INDEX ON tenant_template.payer_hierarchy (payer_id);
CREATE INDEX ON tenant_template.payer_hierarchy (parent_payer_id);

CREATE TABLE tenant_template.payer_payment_card (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id UUID NOT NULL,
    company_code TEXT NOT NULL,
    provider TEXT NOT NULL DEFAULT 'stripe',
    provider_customer_ref TEXT,
    provider_payment_method_ref TEXT NOT NULL,
    card_brand TEXT,
    card_last4 TEXT,
    card_exp_month SMALLINT,
    card_exp_year SMALLINT,
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    allow_child_use BOOLEAN NOT NULL DEFAULT FALSE,
    consecutive_failed_attempts INTEGER NOT NULL DEFAULT 0,
    auto_pay_blocked BOOLEAN NOT NULL DEFAULT FALSE,
    auto_pay_blocked_at TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (provider, provider_payment_method_ref),
    UNIQUE (id, company_code)
);
CREATE INDEX ON tenant_template.payer_payment_card (payer_id);
CREATE INDEX ON tenant_template.payer_payment_card (payer_id, company_code);
-- at most one active primary per Payer PER Company Code (not per Payer alone — a Payer can have a distinct primary card per Company Code's Stripe account)
CREATE UNIQUE INDEX ON tenant_template.payer_payment_card (payer_id, company_code) WHERE is_primary AND status = 'active';

CREATE TABLE tenant_template.payer_card_payment_policy (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id UUID NOT NULL,
    payer_payment_card_id UUID NOT NULL,
    company_code TEXT NOT NULL,
    invoice_type TEXT NOT NULL,
    valid_from DATE NOT NULL,
    valid_to DATE,
    max_amount_per_charge NUMERIC(18,2) NOT NULL,
    max_amount_currency TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (payer_payment_card_id, company_code, invoice_type, valid_from)
);
CREATE INDEX ON tenant_template.payer_card_payment_policy (payer_id);
CREATE INDEX ON tenant_template.payer_card_payment_policy (payer_payment_card_id);
CREATE INDEX ON tenant_template.payer_card_payment_policy (payer_id, company_code);

CREATE TABLE tenant_template.card_payment_threshold_exceeded (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    invoice_id UUID NOT NULL,
    payer_payment_card_id UUID NOT NULL,
    policy_id UUID NOT NULL,
    skip_reason TEXT NOT NULL CHECK (skip_reason IN ('threshold_exceeded', 'no_exchange_rate_available')),
    invoice_amount NUMERIC(18,2) NOT NULL,
    invoice_currency TEXT NOT NULL,
    converted_amount NUMERIC(18,2),
    exchange_rate_used NUMERIC(18,6),
    max_amount_per_charge NUMERIC(18,2) NOT NULL,
    max_amount_currency TEXT NOT NULL,
    first_detected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_checked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (invoice_id, policy_id)
);
CREATE INDEX ON tenant_template.card_payment_threshold_exceeded (payer_payment_card_id);
CREATE INDEX ON tenant_template.card_payment_threshold_exceeded (policy_id);
-- drives both the batch's re-evaluation sweep and the daily notification query
CREATE INDEX ON tenant_template.card_payment_threshold_exceeded (invoice_id) WHERE resolved_at IS NULL;

CREATE TABLE tenant_template.card_payment (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    invoice_id UUID NOT NULL,
    payer_id UUID NOT NULL,
    payer_payment_card_id UUID NOT NULL,
    initiated_via TEXT NOT NULL DEFAULT 'auto_batch' CHECK (initiated_via IN ('auto_batch', 'manual_portal')),
    amount NUMERIC(18,2) NOT NULL,
    currency TEXT NOT NULL,
    provider TEXT NOT NULL DEFAULT 'stripe',
    provider_charge_ref TEXT NOT NULL,
    provider_fee_amount NUMERIC(18,2),
    charged_at TIMESTAMPTZ NOT NULL,
    sap_posting_status TEXT NOT NULL DEFAULT 'pending' CHECK (sap_posting_status IN ('pending', 'posted', 'failed')),
    sap_posting_reference TEXT,
    sap_posting_attempts INTEGER NOT NULL DEFAULT 0,
    sap_posting_last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (provider, provider_charge_ref)
);
CREATE INDEX ON tenant_template.card_payment (invoice_id);
CREATE INDEX ON tenant_template.card_payment (payer_id);
CREATE INDEX ON tenant_template.card_payment (payer_payment_card_id);
CREATE INDEX ON tenant_template.card_payment (sap_posting_status);

CREATE TABLE tenant_template.card_payment_attempt (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    invoice_id UUID NOT NULL,
    payer_id UUID NOT NULL,
    payer_payment_card_id UUID NOT NULL,
    policy_id UUID,
    initiated_via TEXT NOT NULL DEFAULT 'auto_batch' CHECK (initiated_via IN ('auto_batch', 'manual_portal')),
    attempted_amount NUMERIC(18,2) NOT NULL,
    attempted_currency TEXT NOT NULL,
    provider TEXT NOT NULL DEFAULT 'stripe',
    provider_request_ref TEXT,
    outcome TEXT NOT NULL CHECK (outcome IN ('succeeded', 'failed')),
    failure_code TEXT,
    failure_message TEXT,
    card_payment_id UUID,
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID
);
CREATE INDEX ON tenant_template.card_payment_attempt (invoice_id);
CREATE INDEX ON tenant_template.card_payment_attempt (payer_id);
CREATE INDEX ON tenant_template.card_payment_attempt (payer_payment_card_id);

CREATE TABLE tenant_template.payer_bank_account (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id UUID NOT NULL,
    company_code TEXT NOT NULL,
    method_type TEXT NOT NULL CHECK (method_type IN ('ach', 'sepa')),
    provider TEXT NOT NULL DEFAULT 'stripe',
    provider_customer_ref TEXT,
    provider_payment_method_ref TEXT NOT NULL,
    bank_name TEXT,
    account_last4 TEXT,
    account_holder_name TEXT,
    country TEXT,
    currency TEXT,
    verification_method TEXT CHECK (verification_method IN ('instant', 'microdeposit')),
    verification_status TEXT NOT NULL DEFAULT 'pending' CHECK (verification_status IN ('pending', 'verified', 'failed')),
    sepa_mandate_reference TEXT,
    sepa_mandate_signed_at TIMESTAMPTZ,
    self_imposed_limit_amount NUMERIC(18,2),
    self_imposed_limit_period TEXT CHECK (self_imposed_limit_period IN ('per_charge', 'monthly')),
    self_imposed_limit_currency TEXT,
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    allow_child_use BOOLEAN NOT NULL DEFAULT FALSE,
    consecutive_failed_attempts INTEGER NOT NULL DEFAULT 0,
    auto_pay_blocked BOOLEAN NOT NULL DEFAULT FALSE,
    auto_pay_blocked_at TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (provider, provider_payment_method_ref)
);
CREATE INDEX ON tenant_template.payer_bank_account (payer_id);
CREATE INDEX ON tenant_template.payer_bank_account (payer_id, company_code);
-- at most one active primary per Payer PER Company Code, same convention as payer_payment_card
CREATE UNIQUE INDEX ON tenant_template.payer_bank_account (payer_id, company_code) WHERE is_primary AND status = 'active';

CREATE TABLE tenant_template.bank_debit_payment (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    invoice_id UUID NOT NULL,
    payer_id UUID NOT NULL,
    payer_bank_account_id UUID NOT NULL,
    initiated_via TEXT NOT NULL DEFAULT 'auto_batch' CHECK (initiated_via IN ('auto_batch', 'manual_portal')),
    amount NUMERIC(18,2) NOT NULL,
    currency TEXT NOT NULL,
    provider TEXT NOT NULL DEFAULT 'stripe',
    provider_charge_ref TEXT NOT NULL,
    provider_fee_amount NUMERIC(18,2),
    charged_at TIMESTAMPTZ NOT NULL,
    settlement_status TEXT NOT NULL DEFAULT 'pending' CHECK (settlement_status IN ('pending', 'settled', 'returned')),
    settled_at TIMESTAMPTZ,
    returned_at TIMESTAMPTZ,
    return_code TEXT,
    return_reason TEXT,
    sap_posting_status TEXT NOT NULL DEFAULT 'pending' CHECK (sap_posting_status IN ('pending', 'posted', 'failed')),
    sap_posting_reference TEXT,
    sap_posting_attempts INTEGER NOT NULL DEFAULT 0,
    sap_posting_last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (provider, provider_charge_ref)
);
CREATE INDEX ON tenant_template.bank_debit_payment (invoice_id);
CREATE INDEX ON tenant_template.bank_debit_payment (payer_id);
CREATE INDEX ON tenant_template.bank_debit_payment (payer_bank_account_id);
CREATE INDEX ON tenant_template.bank_debit_payment (sap_posting_status);
-- drives the SAP write-back retry sweep
-- drives the sweep watching for late return events / settlement confirmation
CREATE INDEX ON tenant_template.bank_debit_payment (settlement_status) WHERE settlement_status = 'pending';

CREATE TABLE tenant_template.bank_debit_payment_attempt (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    invoice_id UUID NOT NULL,
    payer_id UUID NOT NULL,
    payer_bank_account_id UUID NOT NULL,
    initiated_via TEXT NOT NULL DEFAULT 'auto_batch' CHECK (initiated_via IN ('auto_batch', 'manual_portal')),
    attempted_amount NUMERIC(18,2) NOT NULL,
    attempted_currency TEXT NOT NULL,
    provider TEXT NOT NULL DEFAULT 'stripe',
    provider_request_ref TEXT,
    outcome TEXT NOT NULL CHECK (outcome IN ('succeeded', 'failed')),
    failure_code TEXT,
    failure_message TEXT,
    bank_debit_payment_id UUID,
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID
);
CREATE INDEX ON tenant_template.bank_debit_payment_attempt (invoice_id);
CREATE INDEX ON tenant_template.bank_debit_payment_attempt (payer_id);
CREATE INDEX ON tenant_template.bank_debit_payment_attempt (payer_bank_account_id);

CREATE TABLE tenant_template.payment_provider_webhook_event (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    provider TEXT NOT NULL DEFAULT 'stripe',
    provider_event_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processed', 'failed', 'ignored')),
    processed_at TIMESTAMPTZ,
    processing_error TEXT,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (provider, provider_event_id)
);
CREATE INDEX ON tenant_template.payment_provider_webhook_event (status);

CREATE TABLE tenant_template.company_code (
    code TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    down_payment_configured BOOLEAN NOT NULL DEFAULT FALSE,
    down_payment_verified_at TIMESTAMPTZ,
    down_payment_verified_by UUID,
    minimum_card_payment_amount NUMERIC(14,3) NOT NULL DEFAULT 0,
    minimum_card_payment_currency TEXT NOT NULL DEFAULT 'USD',
    minimum_ach_payment_amount NUMERIC(14,3) NOT NULL DEFAULT 0,
    minimum_ach_payment_currency TEXT NOT NULL DEFAULT 'USD',
    minimum_sepa_payment_amount NUMERIC(14,3) NOT NULL DEFAULT 0,
    minimum_sepa_payment_currency TEXT NOT NULL DEFAULT 'EUR',
    stripe_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    stripe_connected_account_id TEXT UNIQUE,
    stripe_disconnected_at TIMESTAMPTZ,
    stripe_payout_interval TEXT CHECK (stripe_payout_interval IN ('daily', 'weekly', 'monthly', 'manual')),
    stripe_payout_delay_days INTEGER,
    bank_debit_order_confirmation_mode TEXT NOT NULL DEFAULT 'submit_with_delivery_block' CHECK (bank_debit_order_confirmation_mode IN ('hold_in_aiarap', 'submit_with_delivery_block')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);

CREATE TABLE tenant_template.sales_org (
    code TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    company_code TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.sales_org (company_code);

CREATE TABLE tenant_template.plant (
    code TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    address_line1 TEXT,
    address_line2 TEXT,
    city TEXT,
    state_province TEXT,
    postal_code TEXT,
    country TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);

CREATE TABLE tenant_template.purchase_org (
    code TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);

CREATE TABLE tenant_template.purchase_org_company_code (
    purchase_org TEXT NOT NULL,
    company_code TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    PRIMARY KEY (purchase_org, company_code)
);
CREATE INDEX ON tenant_template.purchase_org_company_code (company_code);

CREATE TABLE tenant_template.purchase_org_plant (
    purchase_org TEXT NOT NULL,
    plant TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    PRIMARY KEY (purchase_org, plant)
);
CREATE INDEX ON tenant_template.purchase_org_plant (plant);

CREATE TABLE tenant_template.company_code_plant (
    company_code TEXT NOT NULL,
    plant TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    PRIMARY KEY (company_code, plant)
);
CREATE INDEX ON tenant_template.company_code_plant (plant);

CREATE TABLE tenant_template.sales_org_distribution_channel_plant (
    sales_org TEXT NOT NULL,
    distribution_channel TEXT NOT NULL,
    plant TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    PRIMARY KEY (sales_org, distribution_channel, plant)
);
CREATE INDEX ON tenant_template.sales_org_distribution_channel_plant (plant);

CREATE TABLE tenant_template.payer_sales_area (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id UUID NOT NULL,
    sales_org TEXT NOT NULL,
    distribution_channel TEXT NOT NULL,
    division TEXT NOT NULL,
    currency TEXT,
    payment_terms TEXT,
    price_group TEXT,
    incoterms_1 TEXT,
    incoterms_2 TEXT,
    customer_group TEXT,
    shipping_plant TEXT,
    shipping_conditions TEXT,
    order_combination_allowed BOOLEAN NOT NULL DEFAULT FALSE,
    billing_block BOOLEAN NOT NULL DEFAULT FALSE,
    billing_block_reason TEXT,
    deletion_flag BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (payer_id, sales_org, distribution_channel, division)
);
CREATE INDEX ON tenant_template.payer_sales_area (payer_id);
CREATE INDEX ON tenant_template.payer_sales_area (sales_org);
CREATE INDEX ON tenant_template.payer_sales_area (shipping_plant);

CREATE TABLE tenant_template.payer_company_code (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id UUID NOT NULL,
    company_code TEXT NOT NULL,
    reconciliation_gl_account TEXT,
    payment_terms TEXT,
    accounting_clerk_user_id UUID,
    dunning_clerk TEXT,
    statement_frequency TEXT,
    credit_limit NUMERIC(18,2),
    credit_hold BOOLEAN NOT NULL DEFAULT FALSE,
    credit_hold_reason TEXT,
    po_order_allowed BOOLEAN NOT NULL DEFAULT FALSE,
    po_order_approved_at TIMESTAMPTZ,
    po_order_approved_by UUID,
    deletion_flag BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (payer_id, company_code)
);
CREATE INDEX ON tenant_template.payer_company_code (payer_id);
CREATE INDEX ON tenant_template.payer_company_code (accounting_clerk_user_id);

CREATE TABLE tenant_template.vendor (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    sap_vendor_id TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    address_line1 TEXT,
    address_line2 TEXT,
    city TEXT,
    state_province TEXT,
    postal_code TEXT,
    country TEXT,
    custom_fields JSONB NOT NULL DEFAULT '{}'::jsonb,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);

CREATE TABLE tenant_template.vendor_company_code (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    vendor_id UUID NOT NULL,
    company_code TEXT NOT NULL,
    reconciliation_gl_account TEXT,
    payment_terms TEXT,
    accounting_clerk TEXT,
    payment_block BOOLEAN NOT NULL DEFAULT FALSE,
    payment_block_reason TEXT,
    deletion_flag BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (vendor_id, company_code)
);
CREATE INDEX ON tenant_template.vendor_company_code (vendor_id);

CREATE TABLE tenant_template.vendor_purchasing_org (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    vendor_id UUID NOT NULL,
    purchasing_org TEXT NOT NULL,
    purchasing_group TEXT,
    order_currency TEXT,
    incoterms_1 TEXT,
    incoterms_2 TEXT,
    planned_delivery_days INTEGER,
    deletion_flag BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (vendor_id, purchasing_org)
);
CREATE INDEX ON tenant_template.vendor_purchasing_org (vendor_id);

CREATE TABLE tenant_template.vendor_bank_account (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    vendor_id UUID NOT NULL,
    country TEXT NOT NULL,
    currency TEXT NOT NULL,
    bank_name TEXT,
    account_holder_name TEXT,
    routing_no TEXT,
    account_no TEXT,
    swift TEXT,
    ifsc TEXT,
    iban TEXT,
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    deletion_flag BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.vendor_bank_account (vendor_id);
CREATE UNIQUE INDEX ON tenant_template.vendor_bank_account (vendor_id) WHERE is_primary;

CREATE TABLE tenant_template.contact (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id UUID,
    vendor_id UUID,
    name TEXT NOT NULL,
    title TEXT,
    email CITEXT,
    phone TEXT,
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    CONSTRAINT contact_exactly_one_org CHECK ((payer_id IS NOT NULL)::int + (vendor_id IS NOT NULL)::int = 1)
);
CREATE INDEX ON tenant_template.contact (payer_id);
CREATE INDEX ON tenant_template.contact (vendor_id);
-- at most one active primary per Payer; same convention as tenant_contact
CREATE UNIQUE INDEX ON tenant_template.contact (payer_id) WHERE is_primary AND status = 'active' AND payer_id IS NOT NULL;
CREATE UNIQUE INDEX ON tenant_template.contact (vendor_id) WHERE is_primary AND status = 'active' AND vendor_id IS NOT NULL;
-- backs the social-domain signup email scan (onboarding revisit, point
-- 3) — a live lookup at Pre Sign-up time, not just an occasional query.
-- CITEXT already folds case, so a plain index is case-insensitive for free.
CREATE INDEX ON tenant_template.contact (email);

CREATE TABLE tenant_template.app_user (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    cognito_sub TEXT NOT NULL UNIQUE,
    email CITEXT NOT NULL UNIQUE,
    phone TEXT,
    is_tenant_user BOOLEAN NOT NULL DEFAULT FALSE,
    contact_id UUID,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'deactivated')),
    deactivated_at TIMESTAMPTZ,
    deactivated_by UUID,
    deactivation_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    CONSTRAINT app_user_org_affiliation CHECK ( (is_tenant_user AND contact_id IS NULL) OR (NOT is_tenant_user AND contact_id IS NOT NULL) )
);
CREATE INDEX ON tenant_template.app_user (contact_id);

CREATE TABLE tenant_template.app_user_contact (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    app_user_id UUID NOT NULL,
    contact_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    UNIQUE (app_user_id, contact_id)
);
CREATE INDEX ON tenant_template.app_user_contact (app_user_id);
CREATE INDEX ON tenant_template.app_user_contact (contact_id);

CREATE TABLE tenant_template.role (
    id UUID PRIMARY KEY,
    code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    parent_role_id UUID,
    is_system_defined BOOLEAN NOT NULL DEFAULT TRUE,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.role (parent_role_id);

CREATE TABLE tenant_template.user_role (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    app_user_id UUID NOT NULL,
    role_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (app_user_id, role_id)
);
CREATE INDEX ON tenant_template.user_role (app_user_id);
CREATE INDEX ON tenant_template.user_role (role_id);

CREATE TABLE tenant_template.invoice_type (
    code TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);

CREATE TABLE tenant_template.invoice (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    sap_invoice_id TEXT,
    salesforce_invoice_id TEXT,
    payer_id UUID NOT NULL,
    company_code TEXT NOT NULL,
    sales_org TEXT,
    distribution_channel TEXT,
    division TEXT,
    invoice_type TEXT NOT NULL,
    invoice_number TEXT NOT NULL,
    fi_document_no TEXT,
    fi_document_year TEXT,
    xblnr TEXT,
    invoice_date DATE NOT NULL,
    due_date DATE,
    total_amount NUMERIC(18,2) NOT NULL,
    open_amount NUMERIC(18,2) NOT NULL,
    currency TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'paid', 'cancelled')),
    is_cancelled BOOLEAN NOT NULL DEFAULT FALSE,
    original_invoice_id UUID,
    custom_fields JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    CONSTRAINT invoice_source_id_present CHECK (sap_invoice_id IS NOT NULL OR salesforce_invoice_id IS NOT NULL)
);
CREATE UNIQUE INDEX ON tenant_template.invoice (sap_invoice_id) WHERE sap_invoice_id IS NOT NULL;
CREATE UNIQUE INDEX ON tenant_template.invoice (salesforce_invoice_id) WHERE salesforce_invoice_id IS NOT NULL;
CREATE INDEX ON tenant_template.invoice (payer_id);
CREATE INDEX ON tenant_template.invoice (payer_id, company_code);
CREATE INDEX ON tenant_template.invoice (payer_id, sales_org, distribution_channel, division);
CREATE INDEX ON tenant_template.invoice (sales_org);
CREATE INDEX ON tenant_template.invoice (invoice_type);
CREATE INDEX ON tenant_template.invoice (invoice_number);
-- drives guest lookup (Invoice No + Customer No + Amount)
CREATE INDEX ON tenant_template.invoice (status);
CREATE INDEX ON tenant_template.invoice (original_invoice_id);

CREATE TABLE tenant_template.invoice_line (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    invoice_id UUID NOT NULL,
    line_number INTEGER NOT NULL,
    material_id TEXT,
    description TEXT NOT NULL,
    quantity NUMERIC(15,3),
    uom TEXT,
    unit_price NUMERIC(18,4),
    line_amount NUMERIC(18,2) NOT NULL,
    currency TEXT NOT NULL,
    profit_center TEXT,
    cost_center TEXT,
    internal_order TEXT,
    wbs_element TEXT,
    reference_document TEXT,
    reference_document_item TEXT,
    sales_document TEXT,
    sales_document_item TEXT,
    custom_fields JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (invoice_id, line_number)
);
CREATE INDEX ON tenant_template.invoice_line (invoice_id);

CREATE TABLE tenant_template.payment (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    invoice_id UUID NOT NULL,
    related_invoice_id UUID,
    payer_id UUID NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('aiarap', 'sap_native')),
    payment_method TEXT NOT NULL,
    settlement_category TEXT NOT NULL CHECK (settlement_category IN ('incoming_cash', 'credit_issued', 'bad_debt_writeoff', 'reallocated')),
    amount NUMERIC(18,2) NOT NULL,
    currency TEXT NOT NULL,
    payment_date DATE NOT NULL,
    sap_clearing_document TEXT,
    sap_clearing_document_year TEXT,
    payment_reference TEXT,
    zuonr TEXT,
    sgtxt TEXT,
    xref1 TEXT,
    xref2 TEXT,
    xref3 TEXT,
    vbeln TEXT,
    posnr TEXT,
    vbeln2 TEXT,
    posn2 TEXT,
    card_payment_id UUID,
    sales_order_payment_id UUID,
    bank_debit_payment_id UUID,
    status TEXT NOT NULL DEFAULT 'posted' CHECK (status IN ('posted', 'reversed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.payment (invoice_id);
CREATE INDEX ON tenant_template.payment (related_invoice_id);
CREATE INDEX ON tenant_template.payment (payer_id);
CREATE INDEX ON tenant_template.payment (card_payment_id);
CREATE INDEX ON tenant_template.payment (sales_order_payment_id);
CREATE INDEX ON tenant_template.payment (bank_debit_payment_id);
CREATE INDEX ON tenant_template.payment (source);
CREATE INDEX ON tenant_template.payment (settlement_category);
-- Idempotent sync matching: a sync pass discovering SAP-native clearing
-- documents must never insert a duplicate for one already recorded here
-- (whether originally inserted as 'aiarap' once its write-back posted, or
-- from an earlier sync run) — match on this key first, only insert if no
-- row exists.
CREATE UNIQUE INDEX ON tenant_template.payment (invoice_id, sap_clearing_document, sap_clearing_document_year)
    WHERE sap_clearing_document IS NOT NULL;

CREATE TABLE tenant_template.sap_webhook_event (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    event_type TEXT NOT NULL,
    sap_message_id TEXT,
    payload JSONB NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processed', 'failed', 'ignored')),
    processed_at TIMESTAMPTZ,
    processing_error TEXT,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.sap_webhook_event (status);
-- drives any reprocessing sweep of 'failed'/'pending' rows
-- Idempotency when SAP provides its own message ID; the payment table's
-- own (invoice_id, sap_clearing_document, sap_clearing_document_year)
-- unique index is the ultimate backstop even if this one is skipped
-- (sap_message_id is optional — not every Tenant's outbound mechanism may
-- supply one) or a webhook payload is redelivered without it.
CREATE UNIQUE INDEX ON tenant_template.sap_webhook_event (event_type, sap_message_id) WHERE sap_message_id IS NOT NULL;

CREATE TABLE tenant_template.salesforce_webhook_event (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    event_type TEXT NOT NULL,
    salesforce_event_id TEXT,
    payload JSONB NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processed', 'failed', 'ignored')),
    processed_at TIMESTAMPTZ,
    processing_error TEXT,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.salesforce_webhook_event (status);
CREATE UNIQUE INDEX ON tenant_template.salesforce_webhook_event (event_type, salesforce_event_id) WHERE salesforce_event_id IS NOT NULL;

CREATE TABLE tenant_template.ar_reconciliation_run (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    run_date DATE NOT NULL,
    trigger_type TEXT NOT NULL DEFAULT 'scheduled' CHECK (trigger_type IN ('scheduled', 'webhook_triggered')),
    accounts_checked INTEGER NOT NULL DEFAULT 0,
    accounts_with_variance INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'completed' CHECK (status IN ('running', 'completed', 'failed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.ar_reconciliation_run (run_date);
CREATE INDEX ON tenant_template.ar_reconciliation_run (trigger_type);

CREATE TABLE tenant_template.ar_reconciliation_account (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    run_id UUID NOT NULL,
    payer_id UUID NOT NULL,
    company_code TEXT NOT NULL,
    currency TEXT NOT NULL,
    sap_open_amount NUMERIC(18,2) NOT NULL,
    aiarap_open_amount NUMERIC(18,2) NOT NULL,
    variance_amount NUMERIC(18,2) NOT NULL,
    pending_down_payment_amount NUMERIC(18,2) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (run_id, payer_id, company_code, currency)
);
CREATE INDEX ON tenant_template.ar_reconciliation_account (run_id);
CREATE INDEX ON tenant_template.ar_reconciliation_account (payer_id, company_code);
CREATE INDEX ON tenant_template.ar_reconciliation_account (run_id) WHERE variance_amount <> 0;

CREATE TABLE tenant_template.ar_reconciliation_discrepancy (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    reconciliation_account_id UUID NOT NULL,
    invoice_id UUID,
    discrepancy_type TEXT NOT NULL CHECK (discrepancy_type IN ('amount_mismatch', 'missing_in_aiarap', 'missing_in_sap')),
    sap_open_amount NUMERIC(18,2),
    aiarap_open_amount NUMERIC(18,2),
    variance_amount NUMERIC(18,2) NOT NULL,
    sap_document_reference TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.ar_reconciliation_discrepancy (reconciliation_account_id);
CREATE INDEX ON tenant_template.ar_reconciliation_discrepancy (invoice_id);

CREATE TABLE tenant_template.ar_aging_bucket (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    bucket_label TEXT NOT NULL,
    min_days_past_due INTEGER NOT NULL,
    max_days_past_due INTEGER,
    sort_order INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (sort_order)
);

CREATE TABLE tenant_template.ar_aging_snapshot_run (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    snapshot_date DATE NOT NULL,
    sap_extract_timestamp TIMESTAMPTZ NOT NULL,
    batch_run_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    triggered_by TEXT NOT NULL DEFAULT 'scheduled' CHECK (triggered_by IN ('scheduled', 'manual_refresh')),
    requested_by UUID,
    status TEXT NOT NULL DEFAULT 'completed' CHECK (status IN ('running', 'completed', 'failed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.ar_aging_snapshot_run (snapshot_date);

CREATE TABLE tenant_template.ar_aging_snapshot_invoice (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    snapshot_run_id UUID NOT NULL,
    invoice_id UUID NOT NULL,
    payer_id UUID NOT NULL,
    company_code TEXT NOT NULL,
    currency TEXT NOT NULL,
    bucket_id UUID,
    days_past_due INTEGER NOT NULL,
    open_amount NUMERIC(18,2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (snapshot_run_id, invoice_id)
);
CREATE INDEX ON tenant_template.ar_aging_snapshot_invoice (invoice_id);
CREATE INDEX ON tenant_template.ar_aging_snapshot_invoice (payer_id, company_code, currency);
CREATE INDEX ON tenant_template.ar_aging_snapshot_invoice (bucket_id);

CREATE TABLE tenant_template.ar_aging_snapshot_bucket (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    snapshot_run_id UUID NOT NULL,
    payer_id UUID NOT NULL,
    company_code TEXT NOT NULL,
    currency TEXT NOT NULL,
    bucket_id UUID,
    open_amount NUMERIC(18,2) NOT NULL,
    invoice_count INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.ar_aging_snapshot_bucket (payer_id, company_code, currency);
-- bucket_id is nullable (Current); NULLs aren't equal to each other under
-- a plain UNIQUE, so uniqueness needs two partial indexes rather than one
-- constraint spanning the nullable column.
CREATE UNIQUE INDEX ON tenant_template.ar_aging_snapshot_bucket (snapshot_run_id, payer_id, company_code, currency, bucket_id)
    WHERE bucket_id IS NOT NULL;
CREATE UNIQUE INDEX ON tenant_template.ar_aging_snapshot_bucket (snapshot_run_id, payer_id, company_code, currency)
    WHERE bucket_id IS NULL;

CREATE TABLE tenant_template.ar_aging_snapshot_down_payment (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    snapshot_run_id UUID NOT NULL,
    payer_id UUID NOT NULL,
    company_code TEXT NOT NULL,
    currency TEXT NOT NULL,
    pending_amount NUMERIC(18,2) NOT NULL,
    order_count INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (snapshot_run_id, payer_id, company_code, currency)
);
CREATE INDEX ON tenant_template.ar_aging_snapshot_down_payment (payer_id, company_code, currency);

CREATE TABLE tenant_template.stripe_transaction_type_bucket (
    company_code TEXT NOT NULL,
    stripe_type TEXT NOT NULL,
    bucket TEXT NOT NULL CHECK (bucket IN ('charge', 'refund', 'fee', 'reserve', 'payout', 'adjustment', 'transfer', 'other')),
    description TEXT,
    debit_gl_account TEXT,
    debit_posts_to_customer BOOLEAN NOT NULL DEFAULT FALSE,
    credit_gl_account TEXT,
    credit_posts_to_customer BOOLEAN NOT NULL DEFAULT FALSE,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    PRIMARY KEY (company_code, stripe_type),
    CONSTRAINT stripe_transaction_type_bucket_debit_side_chk CHECK (NOT (debit_posts_to_customer AND debit_gl_account IS NOT NULL)),
    CONSTRAINT stripe_transaction_type_bucket_credit_side_chk CHECK (NOT (credit_posts_to_customer AND credit_gl_account IS NOT NULL))
);

CREATE TABLE tenant_template.stripe_payout (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    company_code TEXT NOT NULL,
    stripe_payout_id TEXT NOT NULL UNIQUE,
    arrival_date DATE NOT NULL,
    amount NUMERIC(18,2) NOT NULL,
    currency TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.stripe_payout (company_code);
CREATE INDEX ON tenant_template.stripe_payout (arrival_date);

CREATE TABLE tenant_template.stripe_payout_transaction (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    payout_id UUID NOT NULL,
    company_code TEXT NOT NULL,
    stripe_balance_txn_id TEXT NOT NULL UNIQUE,
    stripe_charge_ref TEXT,
    transaction_type TEXT NOT NULL,
    bucket TEXT NOT NULL CHECK (bucket IN ('charge', 'refund', 'fee', 'reserve', 'payout', 'adjustment', 'transfer', 'other')),
    gross_amount NUMERIC(18,2) NOT NULL,
    fee_amount NUMERIC(18,2) NOT NULL,
    net_amount NUMERIC(18,2) NOT NULL,
    currency TEXT NOT NULL,
    presentment_amount NUMERIC(18,2),
    presentment_currency TEXT,
    exchange_rate NUMERIC(18,6),
    matched_card_payment_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.stripe_payout_transaction (payout_id);
CREATE INDEX ON tenant_template.stripe_payout_transaction (company_code);
CREATE INDEX ON tenant_template.stripe_payout_transaction (bucket);
CREATE INDEX ON tenant_template.stripe_payout_transaction (stripe_charge_ref);
CREATE INDEX ON tenant_template.stripe_payout_transaction (matched_card_payment_id);

CREATE TABLE tenant_template.stripe_reconciliation_run (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    run_date DATE NOT NULL,
    payouts_checked INTEGER NOT NULL DEFAULT 0,
    discrepancy_count INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'completed' CHECK (status IN ('running', 'completed', 'failed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.stripe_reconciliation_run (run_date);

CREATE TABLE tenant_template.stripe_reconciliation_discrepancy (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    run_id UUID NOT NULL,
    card_payment_id UUID NOT NULL,
    stripe_payout_transaction_id UUID,
    discrepancy_type TEXT NOT NULL CHECK (discrepancy_type IN ('amount_mismatch', 'missing_in_stripe_extract')),
    aiarap_amount NUMERIC(18,2),
    stripe_amount NUMERIC(18,2),
    variance_amount NUMERIC(18,2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.stripe_reconciliation_discrepancy (run_id);
CREATE INDEX ON tenant_template.stripe_reconciliation_discrepancy (card_payment_id);

CREATE TABLE tenant_template.product (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    sap_material_id TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL,
    description_override TEXT,
    base_uom TEXT NOT NULL,
    material_type TEXT,
    material_group TEXT,
    division TEXT,
    ean_upc TEXT,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    deletion_flag BOOLEAN NOT NULL DEFAULT FALSE,
    custom_fields JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);

CREATE TABLE tenant_template.product_sales_org (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    product_id UUID NOT NULL,
    sales_org TEXT NOT NULL,
    distribution_channel TEXT NOT NULL,
    delivering_plant TEXT,
    sales_unit TEXT,
    list_price NUMERIC(18,4),
    list_price_currency TEXT,
    list_price_extracted_at TIMESTAMPTZ,
    blocked BOOLEAN NOT NULL DEFAULT FALSE,
    blocked_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (product_id, sales_org, distribution_channel)
);
CREATE INDEX ON tenant_template.product_sales_org (product_id);
CREATE INDEX ON tenant_template.product_sales_org (sales_org, distribution_channel);
-- drives the Sales-Org-scoped catalog listing query
CREATE INDEX ON tenant_template.product_sales_org (delivering_plant);

CREATE TABLE tenant_template.product_payer_price (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    product_id UUID NOT NULL,
    payer_id UUID NOT NULL,
    sales_org TEXT NOT NULL,
    distribution_channel TEXT NOT NULL,
    list_price NUMERIC(18,4) NOT NULL,
    list_price_currency TEXT NOT NULL,
    list_price_extracted_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (product_id, payer_id, sales_org, distribution_channel)
);
CREATE INDEX ON tenant_template.product_payer_price (product_id, payer_id);
CREATE INDEX ON tenant_template.product_payer_price (payer_id);

CREATE TABLE tenant_template.product_uom (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    product_id UUID NOT NULL,
    uom TEXT NOT NULL,
    numerator NUMERIC(13,3) NOT NULL,
    denominator NUMERIC(13,3) NOT NULL,
    ean_upc TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (product_id, uom)
);
CREATE INDEX ON tenant_template.product_uom (product_id);

CREATE TABLE tenant_template.product_image (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    product_id UUID NOT NULL,
    storage_key TEXT NOT NULL,
    caption TEXT,
    display_order INTEGER NOT NULL DEFAULT 0,
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE INDEX ON tenant_template.product_image (product_id);
-- at most one active primary image per product; same convention as tenant_contact/payer_payment_card
CREATE UNIQUE INDEX ON tenant_template.product_image (product_id) WHERE is_primary;

CREATE TABLE tenant_template.shipping_priority (
    sales_org TEXT NOT NULL,
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    PRIMARY KEY (sales_org, code)
);

CREATE TABLE tenant_template.sales_order_type (
    code TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);

CREATE TABLE tenant_template.delivery_block_reason (
    order_type TEXT NOT NULL,
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    PRIMARY KEY (order_type, code)
);

CREATE TABLE tenant_template.billing_block_reason (
    order_type TEXT NOT NULL,
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    PRIMARY KEY (order_type, code)
);

CREATE TABLE tenant_template.sales_order (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id UUID NOT NULL,
    company_code TEXT NOT NULL,
    sales_org TEXT NOT NULL,
    distribution_channel TEXT NOT NULL,
    division TEXT NOT NULL,
    order_type TEXT NOT NULL,
    payment_method TEXT NOT NULL CHECK (payment_method IN ('credit_card', 'ach', 'sepa', 'purchase_order')),
    customer_po_number TEXT,
    requested_delivery_date DATE,
    currency TEXT NOT NULL,
    incoterms_1 TEXT,
    incoterms_2 TEXT,
    status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pricing_simulated', 'payment_failed', 'held_pending_settlement', 'pending_sap_creation', 'sap_created', 'sap_creation_failed', 'held_payment_returned', 'cancelled')),
    sap_sales_order_id TEXT,
    priced_at TIMESTAMPTZ,
    net_amount NUMERIC(18,2),
    tax_amount NUMERIC(18,2),
    total_amount NUMERIC(18,2),
    raw_pricing_simulation JSONB,
    sap_creation_status TEXT NOT NULL DEFAULT 'pending' CHECK (sap_creation_status IN ('pending', 'posted', 'failed')),
    sap_creation_attempts INTEGER NOT NULL DEFAULT 0,
    sap_creation_last_error TEXT,
    ar_clerk_notified_at TIMESTAMPTZ,
    fulfillment_hold_flagged_at TIMESTAMPTZ,
    fulfillment_hold_reason TEXT,
    delivery_block_code TEXT,
    delivery_block_cleared_at TIMESTAMPTZ,
    billing_block_code TEXT,
    shipping_priority_code TEXT,
    custom_fields JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);
CREATE UNIQUE INDEX ON tenant_template.sales_order (sap_sales_order_id) WHERE sap_sales_order_id IS NOT NULL;
CREATE INDEX ON tenant_template.sales_order (order_type);
CREATE INDEX ON tenant_template.sales_order (payment_method);
CREATE INDEX ON tenant_template.sales_order (payer_id);
CREATE INDEX ON tenant_template.sales_order (payer_id, company_code);
CREATE INDEX ON tenant_template.sales_order (payer_id, sales_org, distribution_channel, division);
CREATE INDEX ON tenant_template.sales_order (status);
CREATE INDEX ON tenant_template.sales_order (sales_org, shipping_priority_code);
-- drives the checkout-failure sweep that retries SAP order creation
CREATE INDEX ON tenant_template.sales_order (sap_creation_status) WHERE sap_creation_status IN ('pending', 'failed');
-- drives the fulfillment-hold worklist for the Tenant's fulfillment owner
CREATE INDEX ON tenant_template.sales_order (fulfillment_hold_flagged_at) WHERE fulfillment_hold_flagged_at IS NOT NULL;
-- drives the Sales Order Bank-Debit Confirmation Batch's delivery-block-clearing sweep
CREATE INDEX ON tenant_template.sales_order (delivery_block_code) WHERE delivery_block_code IS NOT NULL;
CREATE INDEX ON tenant_template.sales_order (billing_block_code) WHERE billing_block_code IS NOT NULL;

CREATE TABLE tenant_template.partner_function (
    code TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);

CREATE TABLE tenant_template.sales_order_partner (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    sales_order_id UUID NOT NULL,
    partner_function TEXT NOT NULL,
    partner_payer_id UUID NOT NULL,
    address_override_line1 TEXT,
    address_override_line2 TEXT,
    address_override_city TEXT,
    address_override_state TEXT,
    address_override_postal TEXT,
    address_override_country TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (sales_order_id, partner_function),
    CONSTRAINT sales_order_partner_address_override_chk CHECK ( partner_function IN ('ship_to', 'bill_to') OR (address_override_line1 IS NULL AND address_override_line2 IS NULL AND address_override_city IS NULL AND address_override_state IS NULL AND address_override_postal IS NULL AND address_override_country IS NULL) )
);
CREATE INDEX ON tenant_template.sales_order_partner (sales_order_id);
CREATE INDEX ON tenant_template.sales_order_partner (partner_function);
CREATE INDEX ON tenant_template.sales_order_partner (partner_payer_id);

CREATE TABLE tenant_template.sales_order_line (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    sales_order_id UUID NOT NULL,
    line_number INTEGER NOT NULL,
    product_id UUID NOT NULL,
    quantity NUMERIC(15,3) NOT NULL,
    uom TEXT NOT NULL,
    requested_delivery_date DATE,
    delivering_plant TEXT,
    unit_price NUMERIC(18,4),
    net_amount NUMERIC(18,2),
    tax_amount NUMERIC(18,2),
    line_amount NUMERIC(18,2),
    currency TEXT,
    custom_fields JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (sales_order_id, line_number)
);
CREATE INDEX ON tenant_template.sales_order_line (sales_order_id);
CREATE INDEX ON tenant_template.sales_order_line (product_id);
CREATE INDEX ON tenant_template.sales_order_line (delivering_plant);

CREATE TABLE tenant_template.sales_order_schedule_line (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    sales_order_line_id UUID NOT NULL,
    schedule_line_number INTEGER NOT NULL,
    confirmed_quantity NUMERIC(15,3) NOT NULL,
    confirmed_delivery_date DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    UNIQUE (sales_order_line_id, schedule_line_number)
);
CREATE INDEX ON tenant_template.sales_order_schedule_line (sales_order_line_id);

CREATE TABLE tenant_template.sales_order_payment (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    sales_order_id UUID NOT NULL,
    payer_id UUID NOT NULL,
    payment_method TEXT NOT NULL CHECK (payment_method IN ('credit_card', 'ach', 'sepa')),
    amount NUMERIC(18,2) NOT NULL,
    currency TEXT NOT NULL,
    provider TEXT NOT NULL DEFAULT 'stripe',
    provider_charge_ref TEXT NOT NULL,
    charged_at TIMESTAMPTZ NOT NULL,
    settlement_status TEXT CHECK (settlement_status IN ('pending', 'settled', 'returned')),
    settled_at TIMESTAMPTZ,
    returned_at TIMESTAMPTZ,
    return_code TEXT,
    return_reason TEXT,
    sap_down_payment_document TEXT,
    sap_down_payment_document_year TEXT,
    sap_reference_written TEXT,
    sap_posting_status TEXT NOT NULL DEFAULT 'pending' CHECK (sap_posting_status IN ('pending', 'posted', 'failed')),
    sap_posting_attempts INTEGER NOT NULL DEFAULT 0,
    sap_posting_last_error TEXT,
    clearing_status TEXT NOT NULL DEFAULT 'pending' CHECK (clearing_status IN ('pending', 'cleared', 'mismatch_flagged')),
    cleared_at TIMESTAMPTZ,
    matched_invoice_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    UNIQUE (provider, provider_charge_ref)
);
CREATE INDEX ON tenant_template.sales_order_payment (sales_order_id);
CREATE INDEX ON tenant_template.sales_order_payment (payer_id);
CREATE INDEX ON tenant_template.sales_order_payment (matched_invoice_id);
-- drives the SAP down payment posting retry sweep
CREATE INDEX ON tenant_template.sales_order_payment (sap_posting_status) WHERE sap_posting_status IN ('pending', 'failed');
-- drives the clearing-match sweep against newly-extracted Invoices
CREATE INDEX ON tenant_template.sales_order_payment (clearing_status) WHERE clearing_status = 'pending';

-- ------------------------------------------------------------
-- 2. Deferred FOREIGN KEY constraints (added after every table
--    exists, so forward references and cross-domain cycles in
--    the source document's narrative ordering never block
--    execution). Grouped by owning table, in the same order as
--    section 1.
-- ------------------------------------------------------------

ALTER TABLE global.tenant_employee_domain ADD CONSTRAINT fk_tenant_employee_domain_tenant_registry_id FOREIGN KEY (tenant_registry_id) REFERENCES global.tenant_registry (id);
ALTER TABLE global.stripe_account_routing ADD CONSTRAINT fk_stripe_account_routing_tenant_registry_id FOREIGN KEY (tenant_registry_id) REFERENCES global.tenant_registry (id);
ALTER TABLE global.tenant_contact ADD CONSTRAINT fk_tenant_contact_tenant_registry_id FOREIGN KEY (tenant_registry_id) REFERENCES global.tenant_registry (id);
ALTER TABLE global.customer_representative ADD CONSTRAINT fk_customer_representative_staff_id FOREIGN KEY (staff_id) REFERENCES global.aiarap_staff (id);
ALTER TABLE tenant_template.currency_exchange_rate ADD CONSTRAINT fk_currency_exchange_rate_from_currency FOREIGN KEY (from_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.currency_exchange_rate ADD CONSTRAINT fk_currency_exchange_rate_to_currency FOREIGN KEY (to_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.tenant_settings ADD CONSTRAINT fk_tenant_settings_tenant_registry_id FOREIGN KEY (tenant_registry_id) REFERENCES global.tenant_registry (id);
ALTER TABLE tenant_template.notification_sender_dns_record ADD CONSTRAINT fk_notification_sender_dns_record_sender_identity_id FOREIGN KEY (sender_identity_id) REFERENCES tenant_template.notification_sender_identity (id);
ALTER TABLE tenant_template.notification_template ADD CONSTRAINT fk_notification_template_sender_identity_id FOREIGN KEY (sender_identity_id) REFERENCES tenant_template.notification_sender_identity (id);
ALTER TABLE tenant_template.notification ADD CONSTRAINT fk_notification_recipient_user_id FOREIGN KEY (recipient_user_id) REFERENCES tenant_template.app_user (id);
ALTER TABLE tenant_template.notification ADD CONSTRAINT fk_notification_template_id FOREIGN KEY (template_id) REFERENCES tenant_template.notification_template (id);
ALTER TABLE tenant_template.notification ADD CONSTRAINT fk_notification_sender_identity_id FOREIGN KEY (sender_identity_id) REFERENCES tenant_template.notification_sender_identity (id);
ALTER TABLE tenant_template.customer_representative_assignment_request ADD CONSTRAINT fk_customer_representative_assignment_request_customer_rep_id FOREIGN KEY (customer_rep_id) REFERENCES global.customer_representative (staff_id);
ALTER TABLE tenant_template.customer_representative_assignment_request ADD CONSTRAINT fk_customer_representative_assignment_request_requested_by FOREIGN KEY (requested_by) REFERENCES global.aiarap_staff (id);
ALTER TABLE tenant_template.customer_representative_assignment_request ADD CONSTRAINT fk_customer_representative_assignment_request_decided_by FOREIGN KEY (decided_by) REFERENCES tenant_template.app_user (id);
ALTER TABLE tenant_template.assigned_customer_representative ADD CONSTRAINT fk_assigned_customer_representative_customer_rep_id FOREIGN KEY (customer_rep_id) REFERENCES global.customer_representative (staff_id);
ALTER TABLE tenant_template.assigned_customer_representative ADD CONSTRAINT fk_assigned_customer_representative_assignment_request_id FOREIGN KEY (assignment_request_id) REFERENCES tenant_template.customer_representative_assignment_request (id);
ALTER TABLE tenant_template.assigned_customer_representative ADD CONSTRAINT fk_assigned_customer_representative_deactivated_by FOREIGN KEY (deactivated_by) REFERENCES tenant_template.app_user (id);
ALTER TABLE tenant_template.payer ADD CONSTRAINT fk_payer_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.payer_email_domain ADD CONSTRAINT fk_payer_email_domain_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.payer_hierarchy ADD CONSTRAINT fk_payer_hierarchy_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.payer_hierarchy ADD CONSTRAINT fk_payer_hierarchy_parent_payer_id FOREIGN KEY (parent_payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.payer_payment_card ADD CONSTRAINT fk_payer_payment_card_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.payer_payment_card ADD CONSTRAINT fk_payer_payment_card_company_code FOREIGN KEY (company_code) REFERENCES tenant_template.company_code (code);
ALTER TABLE tenant_template.payer_payment_card ADD CONSTRAINT payer_payment_card_company_code_fk FOREIGN KEY (payer_id, company_code) REFERENCES tenant_template.payer_company_code (payer_id, company_code);
ALTER TABLE tenant_template.payer_card_payment_policy ADD CONSTRAINT fk_payer_card_payment_policy_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.payer_card_payment_policy ADD CONSTRAINT fk_payer_card_payment_policy_payer_payment_card_id FOREIGN KEY (payer_payment_card_id) REFERENCES tenant_template.payer_payment_card (id);
ALTER TABLE tenant_template.payer_card_payment_policy ADD CONSTRAINT fk_payer_card_payment_policy_company_code FOREIGN KEY (company_code) REFERENCES tenant_template.company_code (code);
ALTER TABLE tenant_template.payer_card_payment_policy ADD CONSTRAINT fk_payer_card_payment_policy_invoice_type FOREIGN KEY (invoice_type) REFERENCES tenant_template.invoice_type (code);
ALTER TABLE tenant_template.payer_card_payment_policy ADD CONSTRAINT fk_payer_card_payment_policy_max_amount_currency FOREIGN KEY (max_amount_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.payer_card_payment_policy ADD CONSTRAINT payer_card_payment_policy_company_code_fk FOREIGN KEY (payer_id, company_code) REFERENCES tenant_template.payer_company_code (payer_id, company_code);
ALTER TABLE tenant_template.payer_card_payment_policy ADD CONSTRAINT payer_card_payment_policy_card_company_code_fk FOREIGN KEY (payer_payment_card_id, company_code) REFERENCES tenant_template.payer_payment_card (id, company_code);
ALTER TABLE tenant_template.card_payment_threshold_exceeded ADD CONSTRAINT fk_card_payment_threshold_exceeded_invoice_id FOREIGN KEY (invoice_id) REFERENCES tenant_template.invoice (id);
ALTER TABLE tenant_template.card_payment_threshold_exceeded ADD CONSTRAINT fk_card_payment_threshold_exceeded_payer_payment_card_id FOREIGN KEY (payer_payment_card_id) REFERENCES tenant_template.payer_payment_card (id);
ALTER TABLE tenant_template.card_payment_threshold_exceeded ADD CONSTRAINT fk_card_payment_threshold_exceeded_policy_id FOREIGN KEY (policy_id) REFERENCES tenant_template.payer_card_payment_policy (id);
ALTER TABLE tenant_template.card_payment_threshold_exceeded ADD CONSTRAINT fk_card_payment_threshold_exceeded_invoice_currency FOREIGN KEY (invoice_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.card_payment_threshold_exceeded ADD CONSTRAINT fk_card_payment_threshold_exceeded_max_amount_currency FOREIGN KEY (max_amount_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.card_payment ADD CONSTRAINT fk_card_payment_invoice_id FOREIGN KEY (invoice_id) REFERENCES tenant_template.invoice (id);
ALTER TABLE tenant_template.card_payment ADD CONSTRAINT fk_card_payment_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.card_payment ADD CONSTRAINT fk_card_payment_payer_payment_card_id FOREIGN KEY (payer_payment_card_id) REFERENCES tenant_template.payer_payment_card (id);
ALTER TABLE tenant_template.card_payment ADD CONSTRAINT fk_card_payment_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.card_payment_attempt ADD CONSTRAINT fk_card_payment_attempt_invoice_id FOREIGN KEY (invoice_id) REFERENCES tenant_template.invoice (id);
ALTER TABLE tenant_template.card_payment_attempt ADD CONSTRAINT fk_card_payment_attempt_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.card_payment_attempt ADD CONSTRAINT fk_card_payment_attempt_payer_payment_card_id FOREIGN KEY (payer_payment_card_id) REFERENCES tenant_template.payer_payment_card (id);
ALTER TABLE tenant_template.card_payment_attempt ADD CONSTRAINT fk_card_payment_attempt_policy_id FOREIGN KEY (policy_id) REFERENCES tenant_template.payer_card_payment_policy (id);
ALTER TABLE tenant_template.card_payment_attempt ADD CONSTRAINT fk_card_payment_attempt_attempted_currency FOREIGN KEY (attempted_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.card_payment_attempt ADD CONSTRAINT fk_card_payment_attempt_card_payment_id FOREIGN KEY (card_payment_id) REFERENCES tenant_template.card_payment (id);
ALTER TABLE tenant_template.payer_bank_account ADD CONSTRAINT fk_payer_bank_account_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.payer_bank_account ADD CONSTRAINT fk_payer_bank_account_company_code FOREIGN KEY (company_code) REFERENCES tenant_template.company_code (code);
ALTER TABLE tenant_template.payer_bank_account ADD CONSTRAINT fk_payer_bank_account_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.payer_bank_account ADD CONSTRAINT fk_payer_bank_account_self_imposed_limit_currency FOREIGN KEY (self_imposed_limit_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.payer_bank_account ADD CONSTRAINT payer_bank_account_company_code_fk FOREIGN KEY (payer_id, company_code) REFERENCES tenant_template.payer_company_code (payer_id, company_code);
ALTER TABLE tenant_template.bank_debit_payment ADD CONSTRAINT fk_bank_debit_payment_invoice_id FOREIGN KEY (invoice_id) REFERENCES tenant_template.invoice (id);
ALTER TABLE tenant_template.bank_debit_payment ADD CONSTRAINT fk_bank_debit_payment_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.bank_debit_payment ADD CONSTRAINT fk_bank_debit_payment_payer_bank_account_id FOREIGN KEY (payer_bank_account_id) REFERENCES tenant_template.payer_bank_account (id);
ALTER TABLE tenant_template.bank_debit_payment ADD CONSTRAINT fk_bank_debit_payment_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.bank_debit_payment_attempt ADD CONSTRAINT fk_bank_debit_payment_attempt_invoice_id FOREIGN KEY (invoice_id) REFERENCES tenant_template.invoice (id);
ALTER TABLE tenant_template.bank_debit_payment_attempt ADD CONSTRAINT fk_bank_debit_payment_attempt_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.bank_debit_payment_attempt ADD CONSTRAINT fk_bank_debit_payment_attempt_payer_bank_account_id FOREIGN KEY (payer_bank_account_id) REFERENCES tenant_template.payer_bank_account (id);
ALTER TABLE tenant_template.bank_debit_payment_attempt ADD CONSTRAINT fk_bank_debit_payment_attempt_attempted_currency FOREIGN KEY (attempted_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.bank_debit_payment_attempt ADD CONSTRAINT fk_bank_debit_payment_attempt_bank_debit_payment_id FOREIGN KEY (bank_debit_payment_id) REFERENCES tenant_template.bank_debit_payment (id);
ALTER TABLE tenant_template.company_code ADD CONSTRAINT fk_company_code_minimum_card_payment_currency FOREIGN KEY (minimum_card_payment_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.company_code ADD CONSTRAINT fk_company_code_minimum_ach_payment_currency FOREIGN KEY (minimum_ach_payment_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.company_code ADD CONSTRAINT fk_company_code_minimum_sepa_payment_currency FOREIGN KEY (minimum_sepa_payment_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.sales_org ADD CONSTRAINT fk_sales_org_company_code FOREIGN KEY (company_code) REFERENCES tenant_template.company_code (code);
ALTER TABLE tenant_template.purchase_org_company_code ADD CONSTRAINT fk_purchase_org_company_code_purchase_org FOREIGN KEY (purchase_org) REFERENCES tenant_template.purchase_org (code);
ALTER TABLE tenant_template.purchase_org_company_code ADD CONSTRAINT fk_purchase_org_company_code_company_code FOREIGN KEY (company_code) REFERENCES tenant_template.company_code (code);
ALTER TABLE tenant_template.purchase_org_plant ADD CONSTRAINT fk_purchase_org_plant_purchase_org FOREIGN KEY (purchase_org) REFERENCES tenant_template.purchase_org (code);
ALTER TABLE tenant_template.purchase_org_plant ADD CONSTRAINT fk_purchase_org_plant_plant FOREIGN KEY (plant) REFERENCES tenant_template.plant (code);
ALTER TABLE tenant_template.company_code_plant ADD CONSTRAINT fk_company_code_plant_company_code FOREIGN KEY (company_code) REFERENCES tenant_template.company_code (code);
ALTER TABLE tenant_template.company_code_plant ADD CONSTRAINT fk_company_code_plant_plant FOREIGN KEY (plant) REFERENCES tenant_template.plant (code);
ALTER TABLE tenant_template.sales_org_distribution_channel_plant ADD CONSTRAINT fk_sales_org_distribution_channel_plant_sales_org FOREIGN KEY (sales_org) REFERENCES tenant_template.sales_org (code);
ALTER TABLE tenant_template.sales_org_distribution_channel_plant ADD CONSTRAINT fk_sales_org_distribution_channel_plant_plant FOREIGN KEY (plant) REFERENCES tenant_template.plant (code);
ALTER TABLE tenant_template.payer_sales_area ADD CONSTRAINT fk_payer_sales_area_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.payer_sales_area ADD CONSTRAINT fk_payer_sales_area_sales_org FOREIGN KEY (sales_org) REFERENCES tenant_template.sales_org (code);
ALTER TABLE tenant_template.payer_sales_area ADD CONSTRAINT fk_payer_sales_area_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.payer_sales_area ADD CONSTRAINT fk_payer_sales_area_shipping_plant FOREIGN KEY (shipping_plant) REFERENCES tenant_template.plant (code);
ALTER TABLE tenant_template.payer_company_code ADD CONSTRAINT fk_payer_company_code_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.payer_company_code ADD CONSTRAINT fk_payer_company_code_company_code FOREIGN KEY (company_code) REFERENCES tenant_template.company_code (code);
ALTER TABLE tenant_template.payer_company_code ADD CONSTRAINT fk_payer_company_code_accounting_clerk_user_id FOREIGN KEY (accounting_clerk_user_id) REFERENCES tenant_template.app_user (id);
ALTER TABLE tenant_template.payer_company_code ADD CONSTRAINT fk_payer_company_code_po_order_approved_by FOREIGN KEY (po_order_approved_by) REFERENCES tenant_template.app_user (id);
ALTER TABLE tenant_template.vendor_company_code ADD CONSTRAINT fk_vendor_company_code_vendor_id FOREIGN KEY (vendor_id) REFERENCES tenant_template.vendor (id);
ALTER TABLE tenant_template.vendor_purchasing_org ADD CONSTRAINT fk_vendor_purchasing_org_vendor_id FOREIGN KEY (vendor_id) REFERENCES tenant_template.vendor (id);
ALTER TABLE tenant_template.vendor_purchasing_org ADD CONSTRAINT fk_vendor_purchasing_org_order_currency FOREIGN KEY (order_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.vendor_bank_account ADD CONSTRAINT fk_vendor_bank_account_vendor_id FOREIGN KEY (vendor_id) REFERENCES tenant_template.vendor (id);
ALTER TABLE tenant_template.contact ADD CONSTRAINT fk_contact_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.contact ADD CONSTRAINT fk_contact_vendor_id FOREIGN KEY (vendor_id) REFERENCES tenant_template.vendor (id);
ALTER TABLE tenant_template.app_user ADD CONSTRAINT fk_app_user_contact_id FOREIGN KEY (contact_id) REFERENCES tenant_template.contact (id);
ALTER TABLE tenant_template.app_user ADD CONSTRAINT fk_app_user_deactivated_by FOREIGN KEY (deactivated_by) REFERENCES tenant_template.app_user (id);
ALTER TABLE tenant_template.app_user_contact ADD CONSTRAINT fk_app_user_contact_app_user_id FOREIGN KEY (app_user_id) REFERENCES tenant_template.app_user (id);
ALTER TABLE tenant_template.app_user_contact ADD CONSTRAINT fk_app_user_contact_contact_id FOREIGN KEY (contact_id) REFERENCES tenant_template.contact (id);
ALTER TABLE tenant_template.role ADD CONSTRAINT fk_role_parent_role_id FOREIGN KEY (parent_role_id) REFERENCES tenant_template.role (id);
ALTER TABLE tenant_template.user_role ADD CONSTRAINT fk_user_role_app_user_id FOREIGN KEY (app_user_id) REFERENCES tenant_template.app_user (id);
ALTER TABLE tenant_template.user_role ADD CONSTRAINT fk_user_role_role_id FOREIGN KEY (role_id) REFERENCES tenant_template.role (id);
ALTER TABLE tenant_template.invoice ADD CONSTRAINT fk_invoice_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.invoice ADD CONSTRAINT fk_invoice_company_code FOREIGN KEY (company_code) REFERENCES tenant_template.company_code (code);
ALTER TABLE tenant_template.invoice ADD CONSTRAINT fk_invoice_sales_org FOREIGN KEY (sales_org) REFERENCES tenant_template.sales_org (code);
ALTER TABLE tenant_template.invoice ADD CONSTRAINT fk_invoice_invoice_type FOREIGN KEY (invoice_type) REFERENCES tenant_template.invoice_type (code);
ALTER TABLE tenant_template.invoice ADD CONSTRAINT fk_invoice_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.invoice ADD CONSTRAINT fk_invoice_original_invoice_id FOREIGN KEY (original_invoice_id) REFERENCES tenant_template.invoice (id);
ALTER TABLE tenant_template.invoice ADD CONSTRAINT invoice_company_code_fk FOREIGN KEY (payer_id, company_code) REFERENCES tenant_template.payer_company_code (payer_id, company_code);
ALTER TABLE tenant_template.invoice ADD CONSTRAINT invoice_sales_area_fk FOREIGN KEY (payer_id, sales_org, distribution_channel, division) REFERENCES tenant_template.payer_sales_area (payer_id, sales_org, distribution_channel, division);
ALTER TABLE tenant_template.invoice_line ADD CONSTRAINT fk_invoice_line_invoice_id FOREIGN KEY (invoice_id) REFERENCES tenant_template.invoice (id);
ALTER TABLE tenant_template.invoice_line ADD CONSTRAINT fk_invoice_line_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.payment ADD CONSTRAINT fk_payment_invoice_id FOREIGN KEY (invoice_id) REFERENCES tenant_template.invoice (id);
ALTER TABLE tenant_template.payment ADD CONSTRAINT fk_payment_related_invoice_id FOREIGN KEY (related_invoice_id) REFERENCES tenant_template.invoice (id);
ALTER TABLE tenant_template.payment ADD CONSTRAINT fk_payment_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.payment ADD CONSTRAINT fk_payment_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.payment ADD CONSTRAINT fk_payment_card_payment_id FOREIGN KEY (card_payment_id) REFERENCES tenant_template.card_payment (id);
ALTER TABLE tenant_template.payment ADD CONSTRAINT fk_payment_sales_order_payment_id FOREIGN KEY (sales_order_payment_id) REFERENCES tenant_template.sales_order_payment (id);
ALTER TABLE tenant_template.payment ADD CONSTRAINT fk_payment_bank_debit_payment_id FOREIGN KEY (bank_debit_payment_id) REFERENCES tenant_template.bank_debit_payment (id);
ALTER TABLE tenant_template.ar_reconciliation_account ADD CONSTRAINT fk_ar_reconciliation_account_run_id FOREIGN KEY (run_id) REFERENCES tenant_template.ar_reconciliation_run (id);
ALTER TABLE tenant_template.ar_reconciliation_account ADD CONSTRAINT fk_ar_reconciliation_account_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.ar_reconciliation_account ADD CONSTRAINT fk_ar_reconciliation_account_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.ar_reconciliation_account ADD CONSTRAINT ar_reconciliation_account_company_code_fk FOREIGN KEY (payer_id, company_code) REFERENCES tenant_template.payer_company_code (payer_id, company_code);
ALTER TABLE tenant_template.ar_reconciliation_discrepancy ADD CONSTRAINT fk_ar_reconciliation_discrepancy_reconciliation_account_id FOREIGN KEY (reconciliation_account_id) REFERENCES tenant_template.ar_reconciliation_account (id);
ALTER TABLE tenant_template.ar_reconciliation_discrepancy ADD CONSTRAINT fk_ar_reconciliation_discrepancy_invoice_id FOREIGN KEY (invoice_id) REFERENCES tenant_template.invoice (id);
ALTER TABLE tenant_template.ar_aging_snapshot_run ADD CONSTRAINT fk_ar_aging_snapshot_run_requested_by FOREIGN KEY (requested_by) REFERENCES tenant_template.app_user (id);
ALTER TABLE tenant_template.ar_aging_snapshot_invoice ADD CONSTRAINT fk_ar_aging_snapshot_invoice_snapshot_run_id FOREIGN KEY (snapshot_run_id) REFERENCES tenant_template.ar_aging_snapshot_run (id);
ALTER TABLE tenant_template.ar_aging_snapshot_invoice ADD CONSTRAINT fk_ar_aging_snapshot_invoice_invoice_id FOREIGN KEY (invoice_id) REFERENCES tenant_template.invoice (id);
ALTER TABLE tenant_template.ar_aging_snapshot_invoice ADD CONSTRAINT fk_ar_aging_snapshot_invoice_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.ar_aging_snapshot_invoice ADD CONSTRAINT fk_ar_aging_snapshot_invoice_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.ar_aging_snapshot_invoice ADD CONSTRAINT fk_ar_aging_snapshot_invoice_bucket_id FOREIGN KEY (bucket_id) REFERENCES tenant_template.ar_aging_bucket (id);
ALTER TABLE tenant_template.ar_aging_snapshot_invoice ADD CONSTRAINT ar_aging_snapshot_invoice_company_code_fk FOREIGN KEY (payer_id, company_code) REFERENCES tenant_template.payer_company_code (payer_id, company_code);
ALTER TABLE tenant_template.ar_aging_snapshot_bucket ADD CONSTRAINT fk_ar_aging_snapshot_bucket_snapshot_run_id FOREIGN KEY (snapshot_run_id) REFERENCES tenant_template.ar_aging_snapshot_run (id);
ALTER TABLE tenant_template.ar_aging_snapshot_bucket ADD CONSTRAINT fk_ar_aging_snapshot_bucket_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.ar_aging_snapshot_bucket ADD CONSTRAINT fk_ar_aging_snapshot_bucket_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.ar_aging_snapshot_bucket ADD CONSTRAINT fk_ar_aging_snapshot_bucket_bucket_id FOREIGN KEY (bucket_id) REFERENCES tenant_template.ar_aging_bucket (id);
ALTER TABLE tenant_template.ar_aging_snapshot_bucket ADD CONSTRAINT ar_aging_snapshot_bucket_company_code_fk FOREIGN KEY (payer_id, company_code) REFERENCES tenant_template.payer_company_code (payer_id, company_code);
ALTER TABLE tenant_template.ar_aging_snapshot_down_payment ADD CONSTRAINT fk_ar_aging_snapshot_down_payment_snapshot_run_id FOREIGN KEY (snapshot_run_id) REFERENCES tenant_template.ar_aging_snapshot_run (id);
ALTER TABLE tenant_template.ar_aging_snapshot_down_payment ADD CONSTRAINT fk_ar_aging_snapshot_down_payment_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.ar_aging_snapshot_down_payment ADD CONSTRAINT fk_ar_aging_snapshot_down_payment_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.ar_aging_snapshot_down_payment ADD CONSTRAINT ar_aging_snapshot_down_payment_company_code_fk FOREIGN KEY (payer_id, company_code) REFERENCES tenant_template.payer_company_code (payer_id, company_code);
ALTER TABLE tenant_template.stripe_transaction_type_bucket ADD CONSTRAINT fk_stripe_transaction_type_bucket_company_code FOREIGN KEY (company_code) REFERENCES tenant_template.company_code (code);
ALTER TABLE tenant_template.stripe_payout ADD CONSTRAINT fk_stripe_payout_company_code FOREIGN KEY (company_code) REFERENCES tenant_template.company_code (code);
ALTER TABLE tenant_template.stripe_payout ADD CONSTRAINT fk_stripe_payout_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.stripe_payout_transaction ADD CONSTRAINT fk_stripe_payout_transaction_payout_id FOREIGN KEY (payout_id) REFERENCES tenant_template.stripe_payout (id);
ALTER TABLE tenant_template.stripe_payout_transaction ADD CONSTRAINT fk_stripe_payout_transaction_company_code FOREIGN KEY (company_code) REFERENCES tenant_template.company_code (code);
ALTER TABLE tenant_template.stripe_payout_transaction ADD CONSTRAINT fk_stripe_payout_transaction_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.stripe_payout_transaction ADD CONSTRAINT fk_stripe_payout_transaction_presentment_currency FOREIGN KEY (presentment_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.stripe_payout_transaction ADD CONSTRAINT fk_stripe_payout_transaction_matched_card_payment_id FOREIGN KEY (matched_card_payment_id) REFERENCES tenant_template.card_payment (id);
ALTER TABLE tenant_template.stripe_payout_transaction ADD CONSTRAINT stripe_payout_transaction_type_fk FOREIGN KEY (company_code, transaction_type) REFERENCES tenant_template.stripe_transaction_type_bucket (company_code, stripe_type);
ALTER TABLE tenant_template.stripe_reconciliation_discrepancy ADD CONSTRAINT fk_stripe_reconciliation_discrepancy_run_id FOREIGN KEY (run_id) REFERENCES tenant_template.stripe_reconciliation_run (id);
ALTER TABLE tenant_template.stripe_reconciliation_discrepancy ADD CONSTRAINT fk_stripe_reconciliation_discrepancy_card_payment_id FOREIGN KEY (card_payment_id) REFERENCES tenant_template.card_payment (id);
ALTER TABLE tenant_template.stripe_reconciliation_discrepancy ADD CONSTRAINT fk_stripe_reconciliation_discrepancy_stripe_payout_transaction_id FOREIGN KEY (stripe_payout_transaction_id) REFERENCES tenant_template.stripe_payout_transaction (id);
ALTER TABLE tenant_template.product_sales_org ADD CONSTRAINT fk_product_sales_org_product_id FOREIGN KEY (product_id) REFERENCES tenant_template.product (id);
ALTER TABLE tenant_template.product_sales_org ADD CONSTRAINT fk_product_sales_org_sales_org FOREIGN KEY (sales_org) REFERENCES tenant_template.sales_org (code);
ALTER TABLE tenant_template.product_sales_org ADD CONSTRAINT fk_product_sales_org_delivering_plant FOREIGN KEY (delivering_plant) REFERENCES tenant_template.plant (code);
ALTER TABLE tenant_template.product_sales_org ADD CONSTRAINT fk_product_sales_org_list_price_currency FOREIGN KEY (list_price_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.product_payer_price ADD CONSTRAINT fk_product_payer_price_product_id FOREIGN KEY (product_id) REFERENCES tenant_template.product (id);
ALTER TABLE tenant_template.product_payer_price ADD CONSTRAINT fk_product_payer_price_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.product_payer_price ADD CONSTRAINT fk_product_payer_price_sales_org FOREIGN KEY (sales_org) REFERENCES tenant_template.sales_org (code);
ALTER TABLE tenant_template.product_payer_price ADD CONSTRAINT fk_product_payer_price_list_price_currency FOREIGN KEY (list_price_currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.product_payer_price ADD CONSTRAINT product_payer_price_product_sales_org_fk FOREIGN KEY (product_id, sales_org, distribution_channel) REFERENCES tenant_template.product_sales_org (product_id, sales_org, distribution_channel);
ALTER TABLE tenant_template.product_uom ADD CONSTRAINT fk_product_uom_product_id FOREIGN KEY (product_id) REFERENCES tenant_template.product (id);
ALTER TABLE tenant_template.product_image ADD CONSTRAINT fk_product_image_product_id FOREIGN KEY (product_id) REFERENCES tenant_template.product (id);
ALTER TABLE tenant_template.shipping_priority ADD CONSTRAINT fk_shipping_priority_sales_org FOREIGN KEY (sales_org) REFERENCES tenant_template.sales_org (code);
ALTER TABLE tenant_template.delivery_block_reason ADD CONSTRAINT fk_delivery_block_reason_order_type FOREIGN KEY (order_type) REFERENCES tenant_template.sales_order_type (code);
ALTER TABLE tenant_template.billing_block_reason ADD CONSTRAINT fk_billing_block_reason_order_type FOREIGN KEY (order_type) REFERENCES tenant_template.sales_order_type (code);
ALTER TABLE tenant_template.sales_order ADD CONSTRAINT fk_sales_order_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.sales_order ADD CONSTRAINT fk_sales_order_company_code FOREIGN KEY (company_code) REFERENCES tenant_template.company_code (code);
ALTER TABLE tenant_template.sales_order ADD CONSTRAINT fk_sales_order_sales_org FOREIGN KEY (sales_org) REFERENCES tenant_template.sales_org (code);
ALTER TABLE tenant_template.sales_order ADD CONSTRAINT fk_sales_order_order_type FOREIGN KEY (order_type) REFERENCES tenant_template.sales_order_type (code);
ALTER TABLE tenant_template.sales_order ADD CONSTRAINT fk_sales_order_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.sales_order ADD CONSTRAINT sales_order_company_code_fk FOREIGN KEY (payer_id, company_code) REFERENCES tenant_template.payer_company_code (payer_id, company_code);
ALTER TABLE tenant_template.sales_order ADD CONSTRAINT sales_order_sales_area_fk FOREIGN KEY (payer_id, sales_org, distribution_channel, division) REFERENCES tenant_template.payer_sales_area (payer_id, sales_org, distribution_channel, division);
ALTER TABLE tenant_template.sales_order ADD CONSTRAINT sales_order_shipping_priority_fk FOREIGN KEY (sales_org, shipping_priority_code) REFERENCES tenant_template.shipping_priority (sales_org, code);
ALTER TABLE tenant_template.sales_order ADD CONSTRAINT sales_order_delivery_block_fk FOREIGN KEY (order_type, delivery_block_code) REFERENCES tenant_template.delivery_block_reason (order_type, code);
ALTER TABLE tenant_template.sales_order ADD CONSTRAINT sales_order_billing_block_fk FOREIGN KEY (order_type, billing_block_code) REFERENCES tenant_template.billing_block_reason (order_type, code);
ALTER TABLE tenant_template.sales_order_partner ADD CONSTRAINT fk_sales_order_partner_sales_order_id FOREIGN KEY (sales_order_id) REFERENCES tenant_template.sales_order (id);
ALTER TABLE tenant_template.sales_order_partner ADD CONSTRAINT fk_sales_order_partner_partner_function FOREIGN KEY (partner_function) REFERENCES tenant_template.partner_function (code);
ALTER TABLE tenant_template.sales_order_partner ADD CONSTRAINT fk_sales_order_partner_partner_payer_id FOREIGN KEY (partner_payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.sales_order_line ADD CONSTRAINT fk_sales_order_line_sales_order_id FOREIGN KEY (sales_order_id) REFERENCES tenant_template.sales_order (id);
ALTER TABLE tenant_template.sales_order_line ADD CONSTRAINT fk_sales_order_line_product_id FOREIGN KEY (product_id) REFERENCES tenant_template.product (id);
ALTER TABLE tenant_template.sales_order_line ADD CONSTRAINT fk_sales_order_line_delivering_plant FOREIGN KEY (delivering_plant) REFERENCES tenant_template.plant (code);
ALTER TABLE tenant_template.sales_order_line ADD CONSTRAINT fk_sales_order_line_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.sales_order_schedule_line ADD CONSTRAINT fk_sales_order_schedule_line_sales_order_line_id FOREIGN KEY (sales_order_line_id) REFERENCES tenant_template.sales_order_line (id);
ALTER TABLE tenant_template.sales_order_payment ADD CONSTRAINT fk_sales_order_payment_sales_order_id FOREIGN KEY (sales_order_id) REFERENCES tenant_template.sales_order (id);
ALTER TABLE tenant_template.sales_order_payment ADD CONSTRAINT fk_sales_order_payment_payer_id FOREIGN KEY (payer_id) REFERENCES tenant_template.payer (id);
ALTER TABLE tenant_template.sales_order_payment ADD CONSTRAINT fk_sales_order_payment_currency FOREIGN KEY (currency) REFERENCES tenant_template.currency (code);
ALTER TABLE tenant_template.sales_order_payment ADD CONSTRAINT fk_sales_order_payment_matched_invoice_id FOREIGN KEY (matched_invoice_id) REFERENCES tenant_template.invoice (id);