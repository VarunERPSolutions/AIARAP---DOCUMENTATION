# React Apps Deployment Reference (react-external-app / react-support-app)

Last updated: 2026-09-08
Companion: `INFRASTRUCTURE_REFERENCE.md` §11a (summary), `terraform/shared/public_apps*.tf`
(actual IaC), `docker/README.md` (node-app/java-app's separate EC2/Docker path,
unaffected by any of this).

Covers the two public-facing React SPAs only. Both were migrated off the
shared `react-app` EC2 instance (now terminated) onto S3 + CloudFront per
[ADR-0038](../adr/0038-portal-support-app-public-exposure-domain-cognito-and-signup.md),
then hardened to a production-grade baseline — see parking lot
[#56](0021-parking-lot.md)/[#57](0021-parking-lot.md) for status.

**Environment: dev only.** qa/prod do not exist yet for either app — see §13
of the architecture audit this doc is drawn from. Custom domain, ACM,
Route53/Hostinger DNS, the Support API's Tailscale-only backend call, and
Cognito/authentication are all deliberately out of scope of this pass.

## 1. Inventory

| | react-external-app | react-support-app |
|---|---|---|
| Repository | `VarunERPSolutions/AIARAP-external-app` | `VarunERPSolutions/AIARAP-support-app` |
| App name | AIARAP Portal | AIARAP Support Console |
| S3 bucket | `varunerp-react-external-app-dev` (us-east-1) | `varunerp-react-support-app-dev` (us-east-1) |
| CloudFront distribution ID | `E3HMX4GXBWZF4C` | `ED3ZDFZ1ZEW4Z` |
| CloudFront domain (live URL) | `https://d1gomc31u4b7fd.cloudfront.net` | `https://d3lb1wndc1hiqd.cloudfront.net` |
| Custom domain | None — default `*.cloudfront.net` only (deferred) | None |
| Deploy trigger | push to `dev` branch | push to `dev` branch |
| CI workflow | `.github/workflows/deploy-dev.yml` | same |

## 2. Architecture

```
GitHub (push to dev)
  -> GitHub Actions (deploy-dev.yml)
       npm ci -> npm run build (Vite)
       -> OIDC assume-role: github-actions-ci
       -> aws s3 sync (Cache-Control set explicitly, see §4)
       -> aws cloudfront create-invalidation (index.html + version.json only)
  -> S3 bucket (private, Block Public Access, SSE-S3, versioned)
       accessible ONLY via CloudFront Origin Access Control (OAC, sigv4)
  -> CloudFront distribution
       WAF (spa-baseline WebACL) -> Response Headers Policy -> Cache Policy
  -> Browser (HTTPS only, redirect-to-https enforced)
```

No EC2, Docker, ECR, or SSM involved anywhere in this path (that path was
fully retired — see §8).

## 3. IAM / CI auth

Both repos assume the shared role `arn:aws:iam::043207749006:role/github-actions-ci`
via GitHub OIDC (no static AWS keys). Trust is scoped to exactly these repos'
`dev` branch. A dedicated inline policy (`github-actions-spa-deploy`) grants
only:
- `s3:ListBucket/GetObject/PutObject/DeleteObject` on the two SPA buckets
- `cloudfront:CreateInvalidation` on the two distributions

**GitHub Actions secrets required per repo**: `AWS_ROLE_ARN`, `SPA_BUCKET_NAME`,
`SPA_DISTRIBUTION_ID`.

## 4. Caching strategy

Deliberate two-tier model, matching Vite's build output
(`index.html` + hashed `assets/*.{js,css}` + a couple of unhashed root
files like `favicon.svg`):

| Path | Cache-Control (set by CI) | CloudFront cache policy | Why |
|---|---|---|---|
| `/assets/*` | `public, max-age=31536000, immutable` | `spa-immutable-assets` (1yr TTL) | Content-hashed filenames — a new deploy never reuses one, so caching forever is safe and never needs invalidating |
| `/index.html` | `no-cache` | `spa-default-no-cache` (0 TTL) | Must always revalidate so a new deploy is visible immediately |
| Everything else (e.g. `favicon.svg`) | `public, max-age=3600` | `spa-default-no-cache` | Unhashed but low-churn — bounded 1hr staleness, self-heals without invalidation |

CI (`deploy-dev.yml`) sets these explicitly via three steps: one full
`aws s3 sync --delete` with the moderate baseline header (handles deletions
correctly), then two `aws s3 cp --recursive`/`cp` overrides for `/assets/*`
and `index.html` respectively.

**Invalidation**: only `/index.html` and `/version.json` are invalidated on
each deploy — hashed assets never need it, and other root files self-heal
within their 1hr TTL. Not a blanket `/*` invalidation.

**`version.json`**: published at the bucket root on every deploy —
`{"commit": "<sha>", "deployedAt": "<ISO8601>"}` — `curl` it to identify
exactly which commit is currently live (used for rollback, see §9).

## 5. Security

- **TLS**: `redirect-to-https` enforced; minimum protocol version is stuck at
  `TLSv1` — this is a hard AWS constraint of using the default CloudFront
  certificate (a custom domain + ACM cert, both deferred, is required to
  raise it).
- **Security headers** (CloudFront Response Headers Policy, one per app):
  `Strict-Transport-Security: max-age=31536000; includeSubDomains`,
  `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`,
  `Referrer-Policy: strict-origin-when-cross-origin`,
  `Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()`.
- **Content-Security-Policy** — tailored per app from actually inspecting
  each app's source (no inline scripts/styles in either):
  - react-external-app: `connect-src 'self'` (no live API calls in this app today)
  - react-support-app: `connect-src 'self' http://java-app.tail14147c.ts.net:4001`
    (its one live call — see §10, DEFERRED, this call is currently blocked by
    browser mixed-content policy regardless of CSP)
- **WAF**: one shared WebACL `spa-baseline` on both distributions —
  `AWSManagedRulesCommonRuleSet`, `AWSManagedRulesKnownBadInputsRuleSet`,
  `AWSManagedRulesAmazonIpReputationList`, `AWSManagedRulesSQLiRuleSet`.
  Logs to CloudWatch Logs (`aws-waf-logs-varunerp-spa`, 30-day retention).
  **Open item**: adversarial testing (classic SQLi/XSS payloads) was not
  conclusively blocked during initial verification — flagged as
  NEEDS FURTHER VERIFICATION, not yet re-confirmed as fixed.
- **S3**: private, Block Public Access (all 4 flags on), OAC-only bucket
  policy scoped to the exact distribution ARN, SSE-S3 encryption,
  **versioning enabled** with a 90-day noncurrent-version expiration
  lifecycle rule (rollback capability).

## 6. Monitoring & logging

- **CloudWatch alarms** (no SNS destination configured — console/API
  visibility only): `<bucket>-cdn-4xx-error-rate` (>20% / 10min),
  `<bucket>-cdn-5xx-error-rate` (>5% / 10min), one pair per app.
- **CloudFront access logs**: delivered to S3 bucket
  `varunerp-cloudfront-logs`, prefixed `react_external/` / `react_support/`,
  90-day lifecycle expiration.
- **WAF logs**: CloudWatch Logs, see §5.

## 7. Rollback

1. `curl https://<cloudfront-domain>/version.json` to see the currently-live commit.
2. `git revert <bad-commit>` (or push a known-good commit) to the app's `dev`
   branch — re-runs the same CI pipeline, a clean forward-fix deploy.
3. Fallback if CI is unavailable: S3 versioning is enabled on both buckets —
   restore previous object versions manually via `aws s3api list-object-versions`
   / `copy-object`, then re-run the CloudFront invalidation for
   `/index.html` + `/version.json`.

## 8. Retired path (verify-only, nothing left)

The old EC2/Docker/ECR/SSM deployment path for these two apps is fully
removed: `react-app` EC2 instance (`i-0404b22a0807d70b3`) terminated
2026-09-08, its ECR repos/images/NLB target groups/listeners/SG rules all
destroyed via Terraform, `Dockerfile`/`nginx.conf` deleted from both repos.
node-app/java-app's own EC2/Docker/ECR/SSM path (`docker/README.md`,
`ci.tf`) is separate and untouched.

Still manual (not Terraform-managed, not yet done): remove the terminated
instance's Tailscale ACL tag/device entry, delete the `reactdev.aiarap.com`
DNS record — see `INFRASTRUCTURE_REFERENCE.md` §12.

## 9. Known out-of-band / unrelated finding

A third CloudFront distribution exists in this AWS account,
`E3MV840LULSXG8` (`www.aiarap.com`, origin bucket `aiarap-frontend-app` in
`ap-southeast-2`), created 2026-06-16 — predates all Terraform work here,
not in this project's Terraform state, different naming convention/region.
**Not part of this deployment, not modified, ownership unconfirmed.**

## 10. Deferred (explicitly out of scope of this pass)

- Custom domain (`reactdev.aiarap.com` or similar)
- ACM certificate for a custom domain
- Route53 / Hostinger DNS changes
- Support API redesign — `react-support-app`'s live call to
  `http://java-app.tail14147c.ts.net:4001` stays as-is; it does not work
  over the public internet today (Tailscale-only host, plain HTTP blocked
  as mixed content on an HTTPS page) — a known, deferred limitation, not a
  regression from this work
- Cognito / authentication — pool `AIARAP_DEV` (`us-east-1_2iggcQC6h`)
  exists in AWS but is not wired into either app's code and was not touched
