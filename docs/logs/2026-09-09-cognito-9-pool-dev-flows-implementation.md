# Cognito 9-Pool Architecture — Dev Flows Implemented, Applied, and Verified

**Date:** 2026-09-09
**Excel row:** `AIARAP_Daily_Implementation_Log.xlsx`, sheet "Daily Log" — "Cognito 9-pool architecture: 2 dev flows applied & verified"

## Source documents used
- [ADR-0038](../adr/0038-portal-support-app-public-exposure-domain-cognito-and-signup.md) (prior Cognito pool design)
- [ADR-0040](../adr/0040-nine-cognito-pool-architecture.md) (written this session)
- `terraform/shared/*.tf`, `terraform/modules/lambda-authorizer/*`, `terraform/modules/tenant-onboarding/*`, `terraform/tenants/*`
- `docs/infra/INFRASTRUCTURE_REFERENCE.md`, `docs/infra/architecture-diagram.html`
- `AIARAP-external-app/`, `AIARAP-support-app/` source (for callback-URL verification)

## Process followed

### 1. Investigation before any change
- Confirmed AWS auth (`aws login`), diagnosed and fixed a stale login-cache conflict.
- Traced the existing single-shared-Cognito-pool design (`varunerp-integration-pool`) and found it was drafted in Terraform but never applied to AWS.
- Found the account has no Route53 hosted zone for either `varunerpsolutions.com` or `aiarap.com`, and the default VPC has no genuinely private subnets — fixed by switching the Cognito auth domain to manual-DNS validation (matching `public_apps_domain.tf`'s existing pattern) and defaulting `private_subnet_ids` to the same public subnets `gateway_network.tf` already reuses.

### 2. Architecture redesign: 4 pools → 9 pools
- User requested a 9-pool architecture (Support / External-Portal / System Comms × dev/qa/prd) for complete isolation by category+environment, explicitly confirmed over several rounds (clarified "Internal App = Support App," "System Communications = existing M2M/invoke purpose").
- Wrote [ADR-0040](../adr/0040-nine-cognito-pool-architecture.md), superseding ADR-0038 §3 only.
- Updated ADR index, ADR-0038's callout, `architecture-diagram.html` (new Figure 7 + pointer callouts on Figures 2/5/6), `terraform/shared/README.md`, `INFRASTRUCTURE_REFERENCE.md`, and the `lambda-authorizer` module README to reflect the new design without misdescribing what's actually applied.
- Implemented the 9-pool Terraform (`cognito.tf`): `for_each` over 3 groups × 3 envs, 12 resource servers, built-in Cognito domains (not custom ACM-backed ones, to avoid needing 9 more manual DNS entries).
- Rewrote the Lambda authorizer (`modules/lambda-authorizer/src/index.js`) for multi-pool JWT verification: decode-unverified-`iss` → match against a Terraform-authored `POOL_MAP` allowlist → cryptographically verify against that specific pool's JWKS → check env/backend/scope. Documented the shared-vs-9-separate-authorizers tradeoff in the module README.
- Fixed real breakage `terraform validate` caught: `flow2.tf` and `modules/tenant-onboarding` still pointed at the old single shared pool — repointed at the new `syscomms-<env>` pools.

### 3. Scope narrowed to 2 active dev flows
- User asked to configure only `portal-dev` (External App) and `support-dev` (Support App) as "active," leaving the other 7 pools provisioned but inert.
- Added `public_apps_cognito.tf` (2 app clients, PKCE/Authorization Code, `generate_secret = false`).
- Scoped the authorizer's `pool_map` to `["support-dev", "portal-dev"]` only via `local.active_pool_keys`.
- **Verified callback/logout URLs against actual app source** (not assumed): found neither `AIARAP-external-app` nor `AIARAP-support-app` has any router or OAuth handling at all. Used root `"/"` as an explicitly-documented temporary placeholder, and documented the requirement that each app must implement PKCE code-exchange on page load — not yet built.

### 4. Terraform hygiene, requested before touching AWS
- Traced all 6 "blocking but out-of-scope" required variables; found 4 of 6 were cleanly separable (`aiarap_com_zone_id` was dead code — deleted; the 3 `aiarap_db_*` vars fed a self-contained inventory-writer concern — extracted to new `terraform/inventory/` root module).
- For the remaining 2 (`sap_proxy_instance_id`, `varunerpsolutions_com_zone_id`, entangled in shared `apis.tf`/`networking.tf` `for_each` blocks): added `PLACEHOLDER` defaults plus **hard-blocking `lifecycle.precondition`** on the actual consuming resources (not the existing `check` block pattern, which was proven to only warn, never block). Proved both directions with real `terraform plan` runs: scoped plan succeeds with zero `-var` flags; untargeted plan hard-fails on all 3 placeholders (including a pre-existing, previously-unguarded `node-prd` placeholder).

### 5. Applied to AWS
- Applied the 2 dev pools, their domains, resource servers, app clients, and the multi-pool Lambda authorizer.
- Hit a real account limit: Lambda concurrency ceiling is only 10 total (`aws lambda get-account-settings`) — `authorizer_reserved_concurrency` (default 50) was impossible on this account. Fixed by defaulting to `-1` (unreserved); the partially-failed Lambda was correctly destroy/recreated by Terraform (tainted-resource handling).
- Found and added `aws_lambda_permission.apigw` — missing from every prior plan this session; without it API Gateway couldn't actually invoke the authorizer.
- Deployed the `node`/`dev` API Gateway path (new NLB + VPC Link, methods, integration, deployment, stage) at the user's explicit go-ahead, after flagging the extra cost/time this introduced.
- Filled both React apps' `.env` files with real, AWS-verified values (`aws cognito-idp describe-user-pool*`), not just apply-log output.

### 6. End-to-end verification
- Confirmed live: no-Authorization-header → `401`; garbage token → `403`.
- Created a throwaway Cognito test user, obtained a real signed token via `USER_AUTH` (not the real Hosted UI flow — documented why: `USER_AUTH` tokens never carry custom OAuth scopes).
- **Found a real, pre-existing bug**: the authorizer's `CognitoJwtVerifier.create(...)` was missing `clientId: null` — required (not optional) by the installed `aws-jwt-verify` version. Every verification attempt was failing before ever checking the token, confirmed via CloudWatch logs. Fixed, redeployed, re-verified: the same real token now fails at the *correct* stage (`missing "node.support"`), proving the entire pipeline up to the final scope check.
- Deleted the test user afterward.

## Outcome
- **Live in AWS**: `varunerp-support-dev-pool`, `varunerp-portal-dev-pool` (+ domains, resource servers, app clients), the multi-pool Lambda authorizer, the `node`/`dev` API Gateway path (NLB + VPC Link + stage), all confirmed working via real HTTP requests and CloudWatch logs.
- **Not yet built**: PKCE code-exchange in either React app (login won't functionally complete without it); `qa`/`prd` and `syscomms` pools remain provisioned but inert.

## Open items / notes for future sessions
- No ADR in the tracked repo formally documents the decision to use AWS API Gateway itself, or the decision to split Node/SAP into two separate REST APIs — both only exist as descriptive Terraform comments and diagram prose. Flagged to the user; offered to draft a proper ADR, not yet actioned. See companion log entry for the documentation-gap-analysis conversation this same day.
- MFA is off on all 9 pools including the 3 prod ones — a silent carry-over from the reference `AIARAP_DEV` pool's baseline, not a considered production decision.
