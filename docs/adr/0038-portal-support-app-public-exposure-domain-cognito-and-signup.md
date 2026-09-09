# Portal & Support App: Public Exposure, Domain/Cognito Structure, and Self-Registration

The single, living record for how `react-external-app` (Payer/Vendor/Tenant-User portal) and `react-support-app` (AIARAP support staff) are publicly reachable, how their Cognito identity is structured, and how a person self-registers into either. **Consolidates and supersedes four ADRs**, each kept in place as a short historical stub pointing here: [0033](0033-public-portal-support-app-exposure.md) (public exposure itself), [0034](0034-per-tenant-portal-domain-and-cognito-pools.md) (per-Tenant domain/pool reopening), [0036](0036-portal-signup-fraud-gate-and-access-decoupled-from-account.md) (the fraud gate + Cognito-account-≠-access insight), [0037](0037-onboarding-self-registration-resolution-paths.md) (the 4 signup resolution paths). Their content lives here now, merged into one current-state narrative rather than four layers of "originally X, then reopened to Y."

**Context**: every server — including `react-app` (hosting both React apps) and `node-app` — used to be reachable only via Tailscale, dev/test-only. That's backwards for production: most real users are outside VarunERP entirely (Payers, Vendors, Tenant Users) or are AIARAP support staff who need only application-level login, not server access.

## 1. Public exposure: both apps, every environment, S3+CloudFront+ACM

Both `react-external-app` and `react-support-app` are public-internet-reachable across dev/qa/prod, not just prod — QA testers and support staff aren't developers making code changes; they shouldn't need Tailscale to reach an app in any environment. **Tailscale's role narrows to exactly what's left needing it**: SSH/direct-server access for developers deploying or debugging code, and infra-admin access (SAP HANA/ADS, Postgres RDS via `aws-subnet-router`). It no longer gates any application HTTP traffic.

Each app builds to static assets in CI and serves via **S3 + CloudFront + ACM**, one distribution per app per environment (6 total: 2 apps × dev/qa/prod) — matching [ADR-0008](0008-frontend-react-spa.md)'s suggestion for a client-rendered SPA with no SSR/SEO need, decoupling frontend availability from any one EC2 instance's health. The `react-app` EC2 instance's nginx containers (the old dev-only deploy target) become redundant — kept only if useful for a developer's local-network preview, otherwise a decommissioning candidate (parking lot #57).

## 2. Backend: reuse the existing Node REST API, three mutually exclusive scopes

Both apps call through the **same Node REST API / Lambda authorizer / internal NLB** already built for Tenant SAP/Salesforce integration. Three scopes exist on the `node-api` Cognito resource server:

- **`node.invoke.<env>`** — M2M, `client_credentials`, Tenant Salesforce/SAP calling in (pre-existing).
- **`node.portal.<env>`** — Payers, Vendors, Tenant Users. Human login via Cognito Hosted UI, Authorization Code + PKCE (a browser SPA can't hold a client secret).
- **`node.support.<env>`** — AIARAP support staff. Same grant type, a distinct Cognito group/app client so a support login can't obtain a portal-scoped token or vice versa.

All three are mutually exclusive by design — a token minted for one has no access under either of the others.

## 3. Cognito pool structure (current state)

> **Superseded by [ADR-0040](0040-nine-cognito-pool-architecture.md) (confirmed).** This section still describes what's actually **live in AWS** today — nothing deployed has changed. ADR-0040's 9-pool design (Support/External-Portal/System-Comms × dev/qa/prd) has been drafted in Terraform and validated, but not yet applied, as of this note.

- **`node.invoke` (M2M) and `node.support` (`react-support-app`)** share one pool, `varunerp-integration-pool`, all three scopes registered on the same resource server. A reasonable default (avoids standing up a second pool/domain for no clear benefit) that's cheap to reverse later — not a hard architectural commitment.
- **`node.portal` (`react-external-app`) — reopened into 3 separate pools, one per environment**: `varunerp-portal-dev-pool`, `varunerp-portal-qa-pool`, `varunerp-portal-prd-pool`, each with its own Hosted UI custom domain. Not one pool per Tenant (unbounded growth for N Tenants) and not the single cross-environment pool used everywhere else — a portal user's dev and prod accounts are deliberately different Cognito identities, matching how dev/qa/prod are already fully separate at every other layer.

`react-support-app` was never part of the per-Tenant reopening below — there was no ask to give AIARAP's own support staff a per-Tenant-branded login, and it wouldn't make sense to (support staff aren't scoped to one Tenant's brand).

## 4. Per-Tenant-branded domain — `react-external-app` only

Each onboarded Tenant gets its own branded portal hostname instead of every Tenant's Payers/Vendors/Tenant Users sharing one generic `portal.aiarap.com`:

- **dev**: `{subdomain}dev.aiarap.com` (e.g. `acmedev.aiarap.com`)
- **qa**: `{subdomain}qa.aiarap.com` (e.g. `acmeqa.aiarap.com`)
- **prd**: `app.{subdomain}.aiarap.com` (e.g. `app.acme.aiarap.com`) — **not** the bare `{subdomain}.aiarap.com` apex.

The prod exception is a discovered constraint, not a style choice: the bare apex is **already** the M2M Tenant-integration domain (`modules/tenant-onboarding`, base-path-mapped at `{subdomain}.aiarap.com/node`). One hostname resolves to exactly one thing — either that API Gateway custom domain or a CloudFront distribution, never both. `app.{subdomain}.aiarap.com` sidesteps the collision without touching the M2M wiring. Dev/qa don't have this problem — `acmedev`/`acmeqa` (concatenated) differ from the M2M convention's `dev.acme`/`qa.acme` (dot-prefixed).

**Infrastructure shape**: the SPA build stays identical across every Tenant (one build, not one per Tenant) — what changes per Tenant is which hostname(s) alias to a given environment's CloudFront distribution. Each environment's distribution gains one additional alias + cert SAN per onboarded Tenant, not a separate bucket/distribution. Provisioning that alias per Tenant is new work (parking lot #60) — natural home is alongside `modules/tenant-onboarding`'s existing per-Tenant cert/domain provisioning, not designed in detail yet.

## 5. Self-registration: Cognito account ≠ application access

Cognito self-service creates a *credential* only — it never by itself grants portal access. This is what reconciles portal self-registration with [ADR-0014](0014-tenant-managed-payer-vendor-user-onboarding-offboarding.md)'s Access-Request-only onboarding, and it falls out of ADR-0014's own design rather than new plumbing: **`User` + `Contact` are created together only on Access Request approval** (ADR-0014, `CONTEXT.md`). A Cognito account can exist — post signup, post the fraud gate below — while **no corresponding AIARAP `User` row exists yet**; the Access Request sits pending, routed exactly as ADR-0014/0015 already specify.

Any real route needs to resolve the caller's Cognito `sub` to an AIARAP `User` regardless (to know which Payer they belong to, what Role they hold) — that lookup finding nothing *is* the enforcement point. A pending Access Request means a valid, correctly-scoped token that `ScopeGuard` happily allows through still hits a dead end the moment a handler tries to resolve who the caller actually is. No new "is this account approved yet" flag is needed — the absence of a `User` row already is that check, for free. (Which flow creates the Cognito identity vs. links to an existing one is still an implementation detail — see Open items.)

## 6. Pre Sign-up fraud gate: 4 resolution paths

Cognito's **Pre Sign-up** Lambda trigger runs synchronously before the user pool record is created and can reject the sign-up outright (no account, nothing to clean up afterward). Each pool (the 3 portal pools, plus a Tenant-employee variant — see 6a) gets one. Four paths, by what the signup's email/hostname resolves to:

**6a. Tenant-employee self-registration** (a Tenant's own internal staff, e.g. Acme's AR/AP team — a category ADR-0014 never covered; Tenant Users have no Contact row). The email domain itself resolves the Tenant, no branded hostname involved. New table `global.tenant_employee_domain` — like `payer_email_domain` below but **globally unique** (it doubles as the bootstrap tenant-resolution mechanism, so two Tenants can never claim the same domain), with `schema_name` denormalized onto it so the Lambda resolves domain → schema in one query. Match → Cognito account created, login permitted, Tenant Admin notified to assign Role(s); no `app_user` row (`is_tenant_user = true`) exists until they do. No Access-Request-style routing needed here — a Tenant Admin already exists for any provisioned Tenant, unlike a brand-new Payer.

**6b. Payer company-domain login** (on the branded hostnames, e.g. `xyz@company1.com` on `acmedev.aiarap.com`). Checked against new table `{tenant}.payer_email_domain` — a Payer can have more than one legal domain (regional units, acquired brands):

```sql
CREATE TABLE payer_email_domain (
    id          UUID PRIMARY KEY DEFAULT uuidv7(),
    payer_id    UUID NOT NULL REFERENCES payer(id),
    domain      TEXT NOT NULL,  -- compared case-insensitively
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    UNIQUE (payer_id, domain)
);
CREATE INDEX ON payer_email_domain (domain);
```

A match both confirms the domain and resolves the specific `payer_id`. Cognito account is created either way; notification routing depends on whether a Payer Admin already exists (`contact` → `app_user` → `user_role` → `role.code = 'payer_admin'`):
- **Admin exists** → notify them directly, auto-created Access Request type = **User** (self-service Admin-request isn't offered once an Admin exists, [ADR-0015](0015-payer-vendor-admin-bootstrap-via-access-request.md)).
- **No Admin yet** → route to ADR-0015's permission-gated bootstrap-approval pool, auto-created Access Request type = **Admin**.

**6c. Payer social-domain login** (`xyz@gmail.com` — can't be domain-matched). Exact case-insensitive match against `{tenant}.contact.email`, unscoped to any one Payer (needed a new index, `CREATE INDEX ON contact (email)`, since this is now a live per-signup lookup). `contact.email` isn't unique — the same person can be a real Contact under more than one Payer (shared consultant). An ambiguous match surfaces the full list of matching Payers and lets the person select one or more, rather than guessing:

```sql
CREATE TABLE app_user_contact (
    id           UUID PRIMARY KEY DEFAULT uuidv7(),
    app_user_id  UUID NOT NULL REFERENCES app_user(id),
    contact_id   UUID NOT NULL REFERENCES contact(id),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    UNIQUE (app_user_id, contact_id)
);
```

`app_user.contact_id` changed meaning from a permanent 1:1 identity to **the currently active account for this login session**, re-pointed at login to whichever `app_user_contact` row is selected — every other query deriving Payer affiliation through it is unaffected. **Role stays uniform across every linked Payer** (confirmed) — `user_role` isn't Payer-scoped; switching the active account changes data scope only. Exactly one match: same admin-exists routing as 6b.

**6d. Rejection messaging**. Zero matches in 6b or 6c: the Lambda throws an `Error` — its message is what the Hosted UI shows the user, no separate notification system needed:
- Missing company domain → ask Acme's sales rep to either register the domain (`payer_email_domain`, if worth trusting for every future employee there) or add this one person as a `contact` instead (the rep's judgment call, not a schema distinction).
- No Contact match on a social domain → ask the sales rep to add the person as a `contact` in Salesforce/SAP, then retry.

Both `payer_email_domain` and `contact` get fixed at the source (the Tenant's own SAP/Salesforce Customer/Contact maintenance), flowing in through the existing extraction/sync pipeline — not a bespoke AIARAP admin screen.

## 7. Tenant-resolution enforcement (still narrowed, not closed)

The SPA populates a `custom:tenant_subdomain` attribute from `window.location.hostname` at signup (e.g. `acmedev.aiarap.com` → `acme`). The Pre Sign-up Lambda (6b/6c above) now validates that claim — looks it up against `global.tenant_registry`, requires the email domain to match a `payer_email_domain` row for **that specific Tenant's** Payer(s), not any Payer platform-wide — rather than blindly trusting it. **Still open** (parking lot #61): this only validates the claim at signup time. What stops an already-issued, correctly-scoped token from later being presented against a *different* Tenant's/Payer's data on some later API call is a separate, runtime, per-request concern — not built.

## Built

- **Terraform** (`terraform/shared/`): S3+CloudFront+ACM (`modules/spa-hosting`, `public_apps.tf`), the Cognito resource-server scopes (`cognito.tf`), one public PKCE app client per app per environment (`public_apps_cognito.tf`). The shared Lambda authorizer (`modules/lambda-authorizer`) accepts any of `invoke`/`portal`/`support`, passing which one matched through as `context.purpose`.
- **`AIARAP-node-backend`**: path-level authorization via `ScopeGuard` (`@RequireScope`, global `APP_GUARD`, fails closed on an unmarked route, independently re-verifies the token since API Gateway's HTTP_PROXY integration doesn't forward authorizer context). Three example controllers demonstrate all three purposes end-to-end; unit- and smoke-tested.
- **Not yet solved by any of this**: per-record ownership (a `portal` token can call an endpoint, but nothing yet stops it fetching a record that isn't the caller's) — each route handler's own responsibility.

## Open items

See [parking lot](0021-parking-lot.md) #56 (CI/CD rework — S3/CloudFront deploy pipeline not built), #57 (`react-app` EC2 decommissioning), #60 (per-Tenant CloudFront alias/cert provisioning), #61 (runtime Tenant-scoping enforcement, narrowed not closed), #63 (Pre Sign-up Lambda infrastructure), #64 (`sub`-to-`app_user` resolution mechanism in NestJS), #65 (multi-Payer account-picker UI/session flow). Also unresolved, not yet in the parking lot: callback/logout URL convention (`/callback`, root `/`) unconfirmed against either app's actual router (doesn't exist yet); any migration plan for portal users already on a pre-reopening shared-pool design (nothing indicates this happened); whether `react-support-app` should ever get per-Tenant treatment (deliberate "no" for now).
