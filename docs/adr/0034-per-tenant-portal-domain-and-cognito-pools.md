# Portal Domain & Cognito Reopened: Per-Tenant-Branded Domain, One Cognito User Pool Per Environment

This ADR **reopens ADR-0033's domain and Cognito-pool decisions for `react-external-app` specifically** — `react-support-app` is explicitly **out of scope** here and keeps ADR-0033's original design unchanged (single shared `support.aiarap.com` domain, single shared user pool, `node.support.<env>` scope). Nothing below applies to it.

## Decision 1: per-Tenant-branded domain, not one shared portal.aiarap.com

Each onboarded Tenant gets its own branded portal hostname instead of every Tenant's Payers/Vendors/Tenant Users sharing one generic `portal.aiarap.com` login page:

- **dev**: `{subdomain}dev.aiarap.com` (e.g. `acmedev.aiarap.com`)
- **qa**: `{subdomain}qa.aiarap.com` (e.g. `acmeqa.aiarap.com`)
- **prd**: `app.{subdomain}.aiarap.com` (e.g. `app.acme.aiarap.com`) — **not** the bare `{subdomain}.aiarap.com` apex.

That last point is a real, discovered constraint, not a style choice: bare `{subdomain}.aiarap.com` is **already** the M2M Tenant-integration domain (`modules/tenant-onboarding`, Figure 2 — Tenant Salesforce/SAP calling in, base-path-mapped at `{subdomain}.aiarap.com/node`). One hostname's DNS record resolves to exactly one thing — either that API Gateway custom domain or a CloudFront distribution, never both. `app.{subdomain}.aiarap.com` sidesteps the collision entirely without touching the already-built M2M domain wiring at all. Dev/qa don't have this problem — `acmedev`/`acmeqa` (concatenated, no dot) are different strings from the M2M convention's `dev.acme`/`qa.acme` (dot-prefixed), so no collision exists there regardless.

**Infrastructure shape**: the SPA build itself stays identical across every Tenant (one build, not one per Tenant) — what changes per Tenant is which hostname(s) are aliased to a given environment's CloudFront distribution. Each environment's distribution (`modules/spa-hosting`, unchanged in shape) gains **one additional alias + one additional cert SAN per onboarded Tenant** rather than spinning up a separate S3 bucket/distribution per Tenant. Provisioning that alias per Tenant is new work, not yet built — the natural home is alongside `modules/tenant-onboarding`'s existing per-Tenant cert/domain provisioning, extended to also request a portal alias, or a new sibling module — not designed here (see Open items).

## Decision 2: Cognito split by environment, not shared, not per-Tenant

Three separate Cognito User Pools — `varunerp-portal-dev-pool`, `varunerp-portal-qa-pool`, `varunerp-portal-prd-pool` — each with its own Hosted UI custom domain. **Every Tenant's portal users for a given environment live in that one environment's pool** — not one pool per Tenant (would mean N pools for N Tenants, an unbounded-growth resource) and not the single cross-environment pool ADR-0033 originally used for everything (`varunerp-integration-pool`) — a portal user's dev account and their prod account are deliberately different Cognito identities in different pools, matching how dev/qa/prod are already fully separate at every other layer (separate S3 buckets, separate NLB target groups, separate app instances).

**Tenant resolution within a shared-per-environment pool**: since Tenant A's and Tenant B's portal users now coexist in the same pool (e.g. both in `varunerp-portal-dev-pool`), something has to keep them apart. Proposed here, not yet built: a required custom attribute (`custom:tenant_subdomain`) set at registration — inferred from which Tenant-branded hostname the user actually registered through (`acmedev.aiarap.com` → `acme`), not manually typed — checked at the application layer (a `ScopeGuard`-adjacent check in `AIARAP-node-backend`, alongside the existing scope check) rather than via a Cognito Group per Tenant, to avoid an unbounded group list as Tenants are onboarded. Not yet designed in detail — see Open items.

## Decision 3: self-registration via Cognito Hosted UI — flagged tension with ADR-0014

As asked for: a Payer/Vendor/Tenant User can sign up directly through Cognito's own Hosted UI sign-up form, not only via a Tenant Admin-driven flow. **This is written down as an explicit, deliberately-flagged assumption, not a quiet decision** — [ADR-0014](0014-tenant-managed-payer-vendor-user-onboarding-offboarding.md) already established that Payer/Vendor onboarding **stays in the Access Request flow**, reviewed/approved rather than self-service. Whether "self-registration in Cognito" here means (a) truly open self-service account creation, reopening ADR-0014, or (b) a Cognito-hosted *credential* is created directly by the user but their actual application-level access still waits on the existing Access Request approval (the Cognito identity exists before the Payer/Vendor role is granted) is **not resolved** — needs a real conversation before this ships, not an assumption baked into infrastructure. See Open items and parking lot.

## Also resolved: which apps this applies to

Only `react-external-app`. `react-support-app` was explicitly not part of this request and keeps its ADR-0033 shape (shared domain, shared pool, `node.support.<env>`) unchanged — there was no ask here to give AIARAP's own support staff a per-Tenant-branded login, and it wouldn't make sense to (support staff aren't scoped to one Tenant's brand).

## Open items

- **Self-registration vs. ADR-0014's Access-Request-only onboarding**: genuinely unresolved tension (Decision 3) — needs a real decision, not an assumption.
- **Per-Tenant CloudFront alias/cert provisioning mechanism**: extending `modules/tenant-onboarding` (or a new sibling module) to add a portal domain alias per Tenant per environment, alongside its existing M2M cert/domain work — not designed.
- **Tenant-resolution mechanism**: `custom:tenant_subdomain` attribute, set from which hostname the user registered through, checked at the application layer — proposed, not designed or built. Includes: what stops a user from registering through `acmedev.aiarap.com` and then presenting their token against `globexdev.aiarap.com`-scoped data (the actual enforcement point).
- **Migration**: any portal users/sessions already using ADR-0033's original shared `portal.aiarap.com`/single-pool design (if that shipped before this reopening) would need a real migration plan — not addressed here, since nothing indicates that happened yet.
- **Whether `react-support-app` should eventually get the same per-Tenant treatment** — explicitly out of scope here (Also resolved, above), but worth a deliberate "no" rather than just an omission if asked again later.
