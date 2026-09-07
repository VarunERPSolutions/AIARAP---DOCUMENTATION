# Public Portal & Support App Exposure: CloudFront+S3, Tailscale Narrowed to Developer/Infra Access Only

Today every server — including `react-app` (hosting both `react-external-app`, the Payer/Vendor/Tenant-User portal, and `react-support-app`, AIARAP's internal support tool) and `node-app` — is reachable only via Tailscale, dev/test-only. That's backwards for production: most real users of both apps have no Tailscale access and never should, since they're outside VarunERP entirely (Payers, Vendors, Tenant Users) or are AIARAP support staff who don't need server-level access, only application-level login.

## Decision

**Both `react-external-app` and `react-support-app` become public-internet-reachable, across every environment (dev/qa/prod)** — not just prod. QA testers and support staff aren't developers making code changes; they shouldn't need Tailscale to reach an app at all, in any environment. **Tailscale's role narrows to exactly what's left needing it**: SSH/direct-server access for developers deploying or debugging code, and infra-admin access (SAP HANA/ADS, Postgres RDS via `aws-subnet-router`). It no longer gates any application HTTP traffic.

Each app is built to static assets in CI and served via **S3 + CloudFront + ACM**, one distribution per app per environment (6 total: 2 apps × dev/qa/prod) — matching [ADR-0008](0008-frontend-react-spa.md)'s own suggestion for a client-rendered SPA with no SSR/SEO need, and decoupling frontend availability from any one EC2 instance's health. The `react-app` EC2 instance's nginx containers (today's dev-only deploy target, `docker/README.md`) become redundant once this ships for all three environments — kept only if useful for a developer's local-network preview, otherwise a candidate for decommissioning (open item below).

## Backend: reuse the existing Node REST API, add two new scopes

Rather than standing up separate public infrastructure for portal/support traffic, both apps call through the **same Node REST API / Lambda authorizer / internal NLB** already built for Tenant SAP/Salesforce integration (see the architecture diagram's Figure 2, `terraform/shared/`). Two new scopes are added to the existing `node-api` Cognito resource server, alongside the pre-existing `node.invoke.<env>` (M2M, `client_credentials`, used by Tenant Salesforce/SAP):

- **`node.portal.<env>`** — Payers, Vendors, Tenant Users. Human login via Cognito Hosted UI, Authorization Code + PKCE grant (not `client_credentials` — a browser SPA can't hold a client secret).
- **`node.support.<env>`** — AIARAP support staff. Same grant type, a distinct Cognito group/app client so a support login is structurally unable to obtain a portal-scoped token or vice versa.

All three scopes (`invoke`, `portal`, `support`) are mutually exclusive by design — a token minted for one has no access under either of the others.

## Built (`terraform/shared/`)

S3+CloudFront+ACM (`modules/spa-hosting`, `public_apps.tf`), the two new resource-server scopes (`cognito.tf`), and one public (no-secret, Authorization Code + PKCE) Cognito app client per app per environment — 6 total — restricted to its own single scope (`public_apps_cognito.tf`). The shared Lambda authorizer (`modules/lambda-authorizer`) now accepts any of `invoke`/`portal`/`support` for a given backend+stage (not just `invoke`), passing which one matched through as `context.purpose` — see that module's README for the exact change and its own now-sharper statement of the gap below.

**Resolved**: Cognito pool structure — built as one shared user pool (`varunerp-integration-pool`), all three scopes as different resource-server scopes on the same `node-api` resource server. Reasonable default (avoids standing up a second pool/domain for no clear benefit yet) and cheap to reverse later if a real reason to split emerges — not treated as a hard architectural commitment.

## Built (`AIARAP-node-backend`)

**Resolved**: path-level authorization. `src/gateway-client/scope.guard.ts`'s `ScopeGuard`, registered globally via `APP_GUARD`, is the enforcement point the Lambda authorizer deliberately doesn't provide — every route needs `@RequireScope('invoke' | 'portal' | 'support')` (or `@Public()`), fails closed on an unmarked route, and independently re-verifies the token's `scope` claim against `node.<purpose>.<env>` (own JWT verification, same `aws-jwt-verify`-against-the-user-pool approach as the Lambda authorizer — necessary since the API Gateway HTTP_PROXY integration has no request-parameter mapping forwarding the authorizer's `context.*` into the backend request). Three example controllers (`ar/invoices` = `portal`, `ar/webhooks/sap-payment` = `invoke`, `shared/support/whoami` = `support`) demonstrate all three purposes end-to-end, including a booted-app smoke test confirming each is rejected without a valid token. Unit-tested (8 cases, including that an `invoke`-scoped token is correctly rejected on a `portal`-only route — the exact gap this closes). See that repo's own README for the full mechanism.

**Not yet solved by this**: per-record ownership (a `portal` token can call an endpoint, but nothing yet stops it from fetching a record that isn't the caller's) — each route handler's own responsibility, not something a scope claim alone can express.

## Open items

- **CI/CD rework**: `terraform/shared/ci.tf` and `docker/README.md` both assume `react-external-app`/`react-support-app` build a Docker image and deploy via SSM to the shared `react-app` EC2 instance. That pipeline needs to become "build static assets → upload to S3 → invalidate CloudFront," per environment, per app — not designed here. `shared/outputs.tf`'s `portal_app_hosting`/`support_app_hosting` (bucket names + distribution IDs) are there for it to consume.
- **Whether the `react-app` EC2 instance is decommissioned** once all three environments serve from S3+CloudFront, or kept around for a developer's local-network preview use case.
- **Callback/logout URL convention unconfirmed**: `public_apps_cognito.tf` assumes both React apps handle the OAuth redirect at `/callback` and post-logout at their root (`/`) — a convention, not verified against either app's actual router/auth code (which doesn't exist yet).
- **`group:qa`** (Tailscale ACL, currently defined with no members — Figure 1) becomes vestigial once dev/qa environments are reachable publicly rather than via Tailscale; worth removing once this ships rather than leaving a stale, unused ACL group around.
