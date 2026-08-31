# Card Expiry Alert and Stripe Card-Data Sync

A new **Card Expiry Alert** job proactively flags `payer_payment_card` rows nearing expiry, notifying the affected Payer's AR Clerk(s) daily until resolved — same recipient mechanism as [ADR-0019](0019-automatic-card-payment-batch.md)'s write-back failure alert. Paired with it, a **Stripe webhook sync** keeps AIARAP's stored `card_exp_month`/`card_exp_year` from silently drifting out of date, since Stripe can refresh a card's underlying data without either the Payer or AIARAP doing anything.

## Why the webhook sync is needed

Stripe's **Network Tokens** and **Card Account Updater (CAU)** mean a card AIARAP has on file can get its expiry/PAN data refreshed automatically when the issuing bank reissues it — no Payer action, no AIARAP involvement, often no visible event at all from AIARAP's side unless it's listening for one. Without syncing that back, `payer_payment_card.card_exp_month`/`card_exp_year` becomes stale the moment Stripe updates its own record, and the Card Expiry Alert job would fire false alarms for cards Stripe already fixed.

**Mechanism (resolved)**: a Stripe webhook handler listens for **`payment_method.automatically_updated`** — the event Stripe fires specifically for `PaymentMethod`-based cards refreshed via Network Tokens/CAU (the legacy `customer.source.updated` event is for the older Sources API and doesn't apply here, since `payer_payment_card.provider_payment_method_ref` stores a `PaymentMethod` ID). Matching on that ref, the handler refreshes `card_exp_month`, `card_exp_year`, `card_last4`, and `card_brand` in place. This is event-driven (NestJS, always-on listener), not a scheduled/cron job — it belongs in `0002-scheduled-jobs.md`'s catalog for visibility even though it doesn't run on a cadence.

### Multi-tenant webhook routing: Stripe Connect

This surfaced a gap this doc hadn't addressed: AIARAP is schema-per-tenant, but Stripe webhooks arrive at one global endpoint — something has to resolve *which* `{tenant}` schema an event belongs to before anything downstream (looking up `payer_payment_card`, etc.) is even possible. Compounding it: **not every Tenant uses Stripe at all** — card payments are optional, and every credit-card-related fact (settings included) should live in that Tenant's own schema, not `global`.

**Decision**: each Tenant that opts in gets its own **Stripe Connected Account** — funds settle directly to that Tenant, never pooled through an AIARAP-controlled account. `tenant_settings.stripe_enabled` (new) gates whether a Tenant participates at all, and gates the Automatic Card Payment batch, Card Expiry Alert, and webhook processing for that Tenant — same pattern as `sap_system_of_record_enabled`/`salesforce_system_of_record_enabled` already on that table. `tenant_settings.stripe_connected_account_id` (new) is the authoritative, app-facing record of the Tenant's connected account.

**The one unavoidable exception**: `global.tenant_registry.stripe_connected_account_id` (new, see `0001-phase-1-table-structures.md`) holds a bare copy of that same ID, purely as a **routing pointer** — no config, no credentials, nothing that would make it a real "Stripe setting." It has to live in `global` for the same structural reason `subdomain`/`schema_name` do (Finding 9 in the table-structures doc): a webhook event carries only the connected account ID, and the receiver cannot query `tenant_settings` to resolve that ID without already knowing which schema to query — a schema-per-tenant deployment has no way around that without either (a) this minimal global pointer, or (b) an extra Stripe API call per webhook to fetch account metadata instead (considered and rejected — adds latency and an external dependency to every single webhook for what a one-column index solves locally). The app layer keeps the two copies in sync at write time, same denormalization convention used elsewhere in this doc (e.g. `card_payment_attempt.payer_id`).

Once routed, every incoming event (not just card-data updates — this is deliberately generic, per ADR-0001's Payment Provider abstraction) is logged to that Tenant's own `payment_provider_webhook_event` table, keyed `UNIQUE(provider, provider_event_id)` for idempotency — Stripe redelivers events, and a redelivery must not reprocess.

## Card Expiry Alert job

- **Tier**: NestJS (lightweight, per-Tenant/per-Payer daily check, no bulk external calls) — same tier as the existing Credential Expiry Alert.
- **Cadence**: daily.
- **Condition**: fires when a `payer_payment_card` (`status = 'active'`) has `card_exp_month`/`card_exp_year` within **10 days** of expiring — proactive, matching the Credential Expiry Alert's precedent, so the AR Clerk has time to get an updated card on file before the Automatic Card Payment batch (ADR-0019) hits a decline. Since the webhook sync above keeps this data current, the alert only fires for cards CAU/network tokens didn't manage to refresh in time — the common case in practice, not the exception.
- **Repeats daily until resolved** — same "no already-alerted flag needed" pattern as Credential Expiry Alert: the condition self-resolves once the card is replaced (new `payer_payment_card` row, old one deactivated) or its data is refreshed by the webhook sync above.
- **Recipient**: every distinct `accounting_clerk_user_id` across the expiring card's Payer's `payer_company_code` rows (deduped) — not a single Tenant Admin, not the Payer — same reasoning and same fallback (no AR Clerk assigned → that Tenant's Admin(s), via the minimal `role`/`user_role` slice) as ADR-0019.

## Stripe Connect onboarding flow (resolved)

A Tenant's own **Stripe Standard connected account** — not Express or Custom — is the right fit here: Standard accounts fully own their own Stripe relationship (their own dashboard, their own compliance/KYC with Stripe directly), while AIARAP only gets delegated permission to create charges and read data on their behalf. This matches the "funds settle directly to the Tenant, never pooled through AIARAP" decision above — a Custom or Express account would put more of the compliance burden and UI surface on AIARAP itself, which isn't the intended relationship.

Flow: a Tenant Admin clicks "Connect Stripe" in Tenant settings → redirected into **Stripe Connect OAuth** → the Admin logs into (or creates) their own Stripe account and authorizes AIARAP's platform application → Stripe redirects back to AIARAP with an authorization code → AIARAP exchanges that code server-side for the Tenant's `stripe_connected_account_id` → both copies (`tenant_settings.stripe_connected_account_id` authoritative, `global.tenant_registry.stripe_connected_account_id` routing pointer) are written together, and `tenant_settings.stripe_enabled` flips to true.

**OAuth scope (resolved): `read_write`.** Stripe Connect's OAuth for Standard accounts offers only two coarse scopes, `read_only` or `read_write` — there's no finer-grained permission set to choose from. `read_only` would block the core use case outright: the Automatic Card Payment batch and manual portal payments both *create* charges/PaymentIntents, and card registration *creates* Customers/PaymentMethods, all of which are write operations. `read_write` is the only option that supports what this platform actually does with the connection.

## Disconnect flow (resolved)

A Tenant Admin clicks "Disconnect Stripe" in Tenant settings, which:

1. Calls Stripe's OAuth deauthorize endpoint (`POST /oauth/deauthorize`, AIARAP's `client_id` + the Tenant's `stripe_connected_account_id`) to formally revoke the grant on Stripe's side — not just an AIARAP-local flag flip.
2. Sets `tenant_settings.stripe_enabled = false` and `stripe_disconnected_at = now()` (new column, see `0001-phase-1-table-structures.md`). **`stripe_connected_account_id` is deliberately NOT cleared** — kept as a historical record, same "deactivation not deletion" convention used throughout this schema — and neither is `global.tenant_registry`'s routing-pointer copy, so a late in-flight webhook for a charge made before disconnect still resolves to the correct Tenant schema and gets logged, rather than being silently dropped for lack of a routing match.
3. Bulk-deactivates every `payer_payment_card` row for that Tenant (`status = 'inactive'`) — once the OAuth grant is revoked, AIARAP can no longer charge any of them, so leaving them `'active'` would let the batch or portal attempt doomed charges against a connection that no longer exists.

A later reconnection is treated as a fresh onboarding flow (step 1 above, run again) — if the Tenant authorizes the same Stripe account, Stripe returns the same connected account ID; a different account simply overwrites it. No assumption is made that a reconnection must match the previous account.

No open items remain for this ADR — see [ADR-0021's Parking Lot](0021-parking-lot.md) for anything raised elsewhere that touches this design.
