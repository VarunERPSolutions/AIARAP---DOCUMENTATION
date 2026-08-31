# Salesforce AppExchange Integration Package

A new inbound integration path lets Tenants using Salesforce (as their system of record, or alongside SAP) call into AIARAP via an AIARAP-built managed package distributed through **Salesforce AppExchange** — the Salesforce-native counterpart to [ADR-0022](0022-sap-payment-webhook.md)'s SAP Payment Webhook, but broader in scope and, structurally, on firmer ground.

## Why this is a stronger position than the SAP equivalent

ADR-0022's design was shaped around a real constraint: many SAP systems, especially older ECC installations, have limited or no outbound REST capability without custom ABAP code or middleware — which is why AIARAP ended up building and shipping the calling program itself, and why bearer-token auth won out over HMAC (matching what SAP's HTTP destinations support natively).

Salesforce doesn't have that constraint. Every Salesforce org supports outbound callouts via Apex, and **Named Credentials** / **External Credentials** are Salesforce's own standard mechanism for secure outbound authentication — including native OAuth 2.0 support — configured declaratively, no custom HTTP client code required. **AppExchange** itself is Salesforce's standardized software distribution channel: a versioned managed package, installed by a Tenant's Salesforce Admin through a wizard, with AIARAP controlling and pushing package upgrades centrally. There's no equivalent to "does this org even support outbound HTTP" question here.

## Scope: broader than payments

Unlike the SAP Payment Webhook (deliberately narrow — SAP-native payments only), this integration is scoped generically from the start. Salesforce is an alternate system of record for the *whole* platform per the spec (Invoices, Customers, Sales Orders — "Payers can also browse the Tenant's product catalog and create Sales Orders"), not just a payment source. `salesforce_webhook_event.event_type` is a wide-open discriminator, not narrowed the way `sap_webhook_event` effectively is in practice — exact event types the package will actually send aren't enumerated here (open item).

## Authentication: OAuth 2.0, not a bearer token

`tenant_settings.salesforce_app_client_id`/`salesforce_app_client_secret_ref` (new) — an OAuth 2.0 client credential pair AIARAP issues per Tenant when their package instance is configured, stored via the same Secrets Manager convention as every other credential on this table. This is a **different pair from the existing `salesforce_credential_secret_ref`/`salesforce_oauth_token_secret_ref` fields** already on `tenant_settings` — those are for AIARAP calling *out* to extract data from Salesforce; these are for the Tenant's installed package calling *in* to AIARAP. `salesforce_app_enabled` gates whether this direction is active at all, independent of `salesforce_system_of_record_enabled`.

## Routing: same URL-embedded-subdomain pattern as the SAP webhook

AIARAP issues the callback URL to each Tenant at package configuration time (embedded in the Named Credential setup), with the Tenant's `subdomain` in the path — no new global lookup needed, same reasoning as ADR-0022 (AIARAP controls the URL it hands out, unlike Stripe's opaque connected-account routing).

## Event log and idempotency

`salesforce_webhook_event` (new) mirrors `sap_webhook_event`'s shape — kept structurally separate as a third distinct integration boundary alongside the Payment Provider abstraction (ADR-0001) and the SAP Integration Adapter (ADR-0022), even though the row shape is similar across all three. Idempotency follows the same two-layer pattern: `salesforce_event_id` when Salesforce's platform event / outbound message mechanism supplies one, with whatever downstream table processes a given event type (e.g. `payment`'s own uniqueness constraints, if the event is payment-related) as the ultimate backstop.

## Design principle: this is the preferred channel for critical data, payloads should carry more than the minimum

Same principle as [ADR-0022](0022-sap-payment-webhook.md)'s SAP program: for critical, money-adjacent event types, the AppExchange package is retained as the primary integration channel, not a narrow trigger a pull-based extraction could eventually replace. As AIARAP's own code running inside the Tenant's Salesforce org, it can attach additional context to each push beyond the bare minimum — e.g. the account's current open balance at the moment of the event — captured in `salesforce_webhook_event.payload` (already `JSONB`, no schema change needed).

Same downstream benefit as the SAP side: this data can supplement **AR Reconciliation** ([ADR-0023](0023-ar-reconciliation-batch.md)) for Salesforce-sourced Tenants, arriving fresher than a periodic batch extraction would.

## Open items

- The exact set of event types the package will send isn't enumerated here — this ADR establishes the generic mechanism, not the specific integrations built on top of it.
- Whether this is a public "Listed" AppExchange package (discoverable/installable by anyone) or a private "Unlisted" one (install links given only to onboarded Tenants) — a go-to-market decision, not a schema one.
- Package versioning/upgrade process across installed Tenant orgs, and how a Salesforce-side detection trigger (Platform Event, Apex trigger on record change, scheduled Apex job) is implemented for each event type — not designed here.
- Whether Salesforce Platform Events (a pub/sub mechanism native to Salesforce) should be used instead of/alongside direct outbound Apex callouts for some event types — not evaluated.
