# Nine Cognito User Pools: Support, System Communications, and External/Portal, Each Split by Environment

**Supersedes [ADR-0038](0038-portal-support-app-public-exposure-domain-cognito-and-signup.md) §3 ("Cognito pool structure") only.** Everything else in ADR-0038 — public exposure via S3+CloudFront+ACM, the three-scope model, per-Tenant-branded portal domains, "Cognito account ≠ application access," and the four self-registration resolution paths — is unaffected and remains the living record for those topics.

**Status: confirmed. Terraform drafted in this branch (`terraform/shared`, `terraform/modules/lambda-authorizer`, `terraform/modules/tenant-onboarding`, `terraform/tenants`) and validated (`terraform validate`, and a scoped `terraform plan`: 39 resources, 0 errors) — not yet applied to real AWS.**

## Decision

Nine Cognito User Pools, one per (application category, environment) pair — not the four ADR-0038 described (one shared pool for M2M+support, three per-environment pools for portal):

```
                    DEV       QA       PRD
------------------------------------------------
Support App         Pool 1    Pool 2   Pool 3
External/Portal     Pool 4    Pool 5   Pool 6
System Comms        Pool 7    Pool 8   Pool 9
```

| Group | Pool name | Who authenticates | Replaces (ADR-0038) |
|---|---|---|---|
| Support — dev | `varunerp-support-dev-pool` | AIARAP support staff (`react-support-app`), dev | part of `varunerp-integration-pool` |
| Support — qa | `varunerp-support-qa-pool` | AIARAP support staff, qa | part of `varunerp-integration-pool` |
| Support — prd | `varunerp-support-prd-pool` | AIARAP support staff, prd | part of `varunerp-integration-pool` |
| External/Portal — dev | `varunerp-portal-dev-pool` | Payers, Vendors, Tenant Users (`react-external-app`), dev | `varunerp-portal-dev-pool` (unchanged) |
| External/Portal — qa | `varunerp-portal-qa-pool` | Same, qa | `varunerp-portal-qa-pool` (unchanged) |
| External/Portal — prd | `varunerp-portal-prd-pool` | Same, prd | `varunerp-portal-prd-pool` (unchanged) |
| System Comms — dev | `varunerp-syscomms-dev-pool` | M2M — Tenant Salesforce/SAP, VarunERP's own Salesforce (`client_credentials`), dev | part of `varunerp-integration-pool` |
| System Comms — qa | `varunerp-syscomms-qa-pool` | Same, qa | part of `varunerp-integration-pool` |
| System Comms — prd | `varunerp-syscomms-prd-pool` | Same, prd | part of `varunerp-integration-pool` |

**"Internal App" = "Support App" — confirmed.** These are the same application (`react-support-app`, AIARAP's own staff). There is no separate "Internal App" pool group; none exists in the Terraform below.

**"System Communications" = the existing M2M purpose — confirmed.** Exactly what ADR-0038 called `node.invoke`/`sap.invoke`: Tenant Salesforce/SAP and VarunERP's own Salesforce calling in via `client_credentials`, no human ever holding one of these tokens. The syscomms pools host **both** the `node-api` and `sap-api` resource servers (implemented — see Terraform structure below).

## Why 4 pools → 9 pools

**Complete isolation by application category and environment — confirmed as the reason.** A dedicated pool per (category, environment) gives clearer security boundaries (a prd Support pool compromise can't reach prd System Comms or Portal credentials, not even via a shared pool's other app clients), independent per-pool configuration, and room to scale each category independently — accepted deliberately, alongside the added infrastructure and operational overhead (9 pools instead of 4 to administer, monitor, and eventually rotate/patch) that isolation costs.

## Existing `AIARAP_DEV` pool: reference only, not reused

```
Pool:   AIARAP_DEV (us-east-1_2iggcQC6h)
Client: AIARAP_DEV_COGNITO (vgo1pinp7439fl29satsqhf43)
```

Confirmed via `aws cognito-idp describe-user-pool`/`describe-user-pool-client` (2026-09-09). This pool is **not** imported, modified, migrated, or referenced by ID anywhere in the Terraform below — grepped the full `terraform/` tree after drafting to confirm zero references to `us-east-1_2iggcQC6h` or `AIARAP_DEV`. It stays exactly as-is, used only as a settings reference (below) for the 9 new pools. It is currently used by the External App in dev per instruction — note this still isn't reflected in the repo itself: both `AIARAP-external-app/.env` and `AIARAP-support-app/.env` have blank `VITE_COGNITO_USER_POOL_ID`/`VITE_COGNITO_CLIENT_ID`. Retirement of `AIARAP_DEV` once the real `portal-dev` pool exists is not decided — still open, not urgent (see Open items).

**Baseline settings carried over to all 9 new pools** (implemented in `terraform/shared/cognito.tf`'s `aws_cognito_user_pool.app`):

| Setting | `AIARAP_DEV` value | Carried over? |
|---|---|---|
| Password policy | Min length 8, requires upper/lower/number/symbol, temp password valid 7 days | Yes, all 9 pools |
| MFA | Off | Yes, all 9 pools **including the 3 prd pools** — see Open items, this is a deliberate carry-over, not re-litigated here |
| Username attribute | `email` | Yes |
| Auto-verified attributes | `email` | Yes |
| Account recovery | `verified_email` (priority 1), `verified_phone_number` (priority 2) | Yes |
| Deletion protection | `ACTIVE` | Yes |
| User pool tier | `ESSENTIALS` | Yes |
| `PreventUserExistenceErrors` / `EnableTokenRevocation` | `ENABLED` / `true` | Not yet implemented — these live on the app **client**, not the pool, and this draft deliberately doesn't create app clients yet (see Remaining gaps) |

## Resource servers and scopes per pool — implemented

Each pool hosts a resource server per backend relevant to its group, with **no environment suffix on the scope name** (`node.support`, `node.portal`, `node.invoke`, `sap.invoke` — not `node.support.dev`) since the pool itself now encodes environment:

- **Support pools (3)**: `node-api` resource server, scope `node.support`.
- **Portal pools (3)**: `node-api` resource server, scope `node.portal`.
- **System Comms pools (3)**: **both** `node-api` (scope `node.invoke`) and `sap-api` (scope `sap.invoke`) resource servers.

12 resource servers total (3 + 3 + 3×2), matching the scoped `terraform plan`.

## Terraform structure — implemented

`terraform/shared/cognito.tf`, fully rewritten:

```hcl
locals {
  cognito_groups = {
    support  = { scopes = { node = "node.support" } }
    portal   = { scopes = { node = "node.portal" } }
    syscomms = { scopes = { node = "node.invoke", sap = "sap.invoke" } }
  }
  cognito_environments = ["dev", "qa", "prd"]
  cognito_pools = {
    for pair in setproduct(keys(local.cognito_groups), local.cognito_environments) :
    "${pair[0]}-${pair[1]}" => { group = pair[0], env = pair[1] }
  }
  # flattened (pool, backend) -> resource server config, one entry per
  # aws_cognito_resource_server this file creates
  cognito_resource_servers = merge([for pool_key, pool in local.cognito_pools : {
    for backend, scope_name in local.cognito_groups[pool.group].scopes :
    "${pool_key}-${backend}" => { pool_key = pool_key, backend = backend, scope_name = scope_name, ... }
  }]...)
}

resource "aws_cognito_user_pool" "app" {
  for_each = local.cognito_pools
  name     = "varunerp-${each.value.group}-${each.value.env}-pool"
  # ...AIARAP_DEV baseline settings...
}

resource "aws_cognito_user_pool_domain" "app" {
  for_each     = local.cognito_pools
  domain       = "varunerp-${each.value.group}-${each.value.env}"
  user_pool_id = aws_cognito_user_pool.app[each.key].id
}

resource "aws_cognito_resource_server" "app" {
  for_each     = local.cognito_resource_servers
  identifier   = each.value.backend == "node" ? "https://api.aiarap.com/node" : "https://api.varunerpsolutions.com/sap"
  name         = "${each.value.backend}-api"
  user_pool_id = aws_cognito_user_pool.app[each.value.pool_key].id
  scope { scope_name = each.value.scope_name }
}
```

**Mapping to applications/environments/clients/resource servers/scopes:**

| Layer | Shape |
|---|---|
| Application category | `local.cognito_groups` — 3 entries (`support`, `portal`, `syscomms`), each declaring which backend(s)+scope(s) it needs |
| Environment | `local.cognito_environments` — `["dev", "qa", "prd"]` |
| Pool | `aws_cognito_user_pool.app`, `for_each` over the 3×3 = 9 cross product |
| Domain | `aws_cognito_user_pool_domain.app`, one built-in `<prefix>.auth.<region>.amazoncognito.com` domain per pool — **not** a custom ACM-backed domain (see Deliberately deferred, below) |
| Resource server | `aws_cognito_resource_server.app`, one per (pool, backend) — 12 total |
| App clients | **Not created in this draft** — see Remaining gaps |

**Deliberately deferred, not part of this draft:**
- **App clients** (the actual PKCE clients `react-external-app`/`react-support-app` would use, and per-Tenant M2M clients) — the task asked for pools + resource servers + API Gateway/authorizer integration, not clients. Per-Tenant M2M clients are unaffected structurally: `modules/tenant-onboarding` still creates them, now pointed at the matching `syscomms-<env>` pool instead of the old shared pool (fixed as part of this draft — see Remaining gaps for why this needed touching).
- **Custom branded Hosted UI domains** — 9 pools would mean 9 ACM certs + 9 manual Hostinger DNS entries (confirmed via `aws route53 list-hosted-zones-by-name`: no Route53 zone exists for either `aiarap.com` or `varunerpsolutions.com` in this account). Each pool uses Cognito's free built-in domain instead. The old shared pool's `auth.varunerpsolutions.com` custom domain (and its ACM cert / manual-DNS outputs) is removed along with the pool it belonged to.

## API Gateway / Lambda authorizer — implemented

Full design and rationale now live in `terraform/modules/lambda-authorizer/README.md` (the authoritative copy — summarized here to keep this ADR from drifting out of sync with the actual code):

**Pipeline** (`terraform/modules/lambda-authorizer/src/index.js`, rewritten):
```
Access Token
     ↓
extract bearer token
     ↓
decode iss WITHOUT verifying (base64url-decode the JWT payload only)
     ↓
match iss against POOL_MAP (Terraform-authored allowlist of exactly the 9 pool IDs created above)
     — no match → deny here, before any cryptographic check
     ↓
verify the token CRYPTOGRAPHICALLY against the matched pool's own JWKS
  (aws-jwt-verify's CognitoJwtVerifier, keyed to that specific pool ID —
  it independently re-derives the expected issuer from userPoolId+region
  and checks the token's iss against THAT, so a spoofed iss can't produce
  a false Allow even if the lookup above were somehow tricked)
     — fails → deny
     ↓
resolve backend (apiId → API_BACKEND_MAP) and environment (requestContext.stage)
     ↓
check matched pool's env == stage, and pool's group is permitted to call this backend
     ↓
check verified scope claim contains the group's required scope (node.support / node.portal / node.invoke / sap.invoke)
     ↓
Allow (IAM policy, stage/*/* wildcard) / Deny
```

**The critical property, stated explicitly since it was the point of this exercise**: the unverified `iss` is used **only to select which of 9 pre-configured, Terraform-authored verifiers to run** — it is never itself a trust decision, and it never causes a verifier to be constructed for an issuer Terraform didn't already provision. Verification is still fully cryptographic (signature + expiry + `token_use` + issuer, via `aws-jwt-verify` against the real JWKS) for every request; nothing about supporting 9 issuers weakens that.

**One shared Lambda for all 9 pools, not 9 separate authorizers — decided, with tradeoffs recorded in the module README**:
- **Latency**: `CognitoJwtVerifier.create()` doesn't fetch JWKS eagerly (only on first `.verify()` per pool, cached for the container's life) — building 9 verifiers at cold start costs 9 cheap object constructions, not 9 upfront network calls. Splitting into 9 functions would instead multiply *cold starts*, since traffic per pool is now spread thinner across more independently-scaling functions.
- **Security**: identical either way — the trust boundary is `POOL_MAP` plus per-pool JWKS verification, not which Lambda happens to run the code. 9 functions would add 9x the IAM roles/log groups to keep in sync for no isolation benefit, since a `support-dev` token still can't pass as `portal-prd` regardless of how many functions exist.
- **Operational**: one codebase, one deploy — already the existing pattern (one function, multiple `aws_api_gateway_authorizer` attachments across `node`/`sap`), just extended from 1 trusted pool to 9.

## Remaining gaps this draft surfaced (not part of the original ask, fixed anyway)

`terraform validate` caught two real consumers of the old single-pool design that would otherwise have silently broken:

- **`flow2.tf`** (VarunERP's own Salesforce→SAP client) pointed directly at `aws_cognito_user_pool.shared` and `aws_cognito_resource_server.sap` — repointed at the matching `syscomms-<env>` pool/resource-server.
- **`modules/tenant-onboarding`** (per-Tenant M2M client provisioning) took a single `cognito_user_pool_id`/`cognito_domain` — both changed to maps keyed by environment (`cognito_user_pool_ids`, `cognito_domains`), and `terraform/tenants` (its caller) updated to match. Each Tenant connection's app client now attaches to *that connection's own environment's* `syscomms` pool, not one shared pool. The connection scope string also dropped its `<env>` suffix, matching the rest of this ADR.

## Open items

- **MFA for the 3 prd pools** — carried over as "off" from `AIARAP_DEV` for all 9 pools, prd included. Not re-opened by this draft; flagged again here in case that's worth revisiting before an actual `apply`.
- **App client provisioning** — still not built for Support/Portal (the pre-existing `public_apps_cognito.tf` gap ADR-0038 already flagged), and per-Tenant System Comms clients now correctly target the right pool but weren't otherwise redesigned.
- **`AIARAP_DEV` retirement plan** — no decision recorded on whether/when it's deleted once `portal-dev` exists for real.
- **Custom Hosted UI branding** — deliberately deferred (built-in Cognito domains only); revisit if branding on these login pages becomes a real requirement.
