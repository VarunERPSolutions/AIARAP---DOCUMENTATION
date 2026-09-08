# Walkthrough: adding a custom domain to a CloudFront SPA

A learning-oriented write-up of exactly how `dev.support.aiarap.com` was
wired onto the react-support-app CloudFront distribution. Written so the
same steps can be repeated for another app/subdomain without re-deriving
them. For the resulting end-state (what exists today), see
`REACT_APPS_DEPLOYMENT.md`; this doc is about the *process*, in order.

## The concepts, briefly

- **CloudFront only serves a custom hostname if two things are both true**:
  (1) the distribution has the hostname listed in its `Aliases`, and
  (2) the distribution has a TLS certificate that covers that hostname.
  CloudFront's own default certificate (`*.cloudfront.net`) never covers a
  custom domain — you always need your own cert for that part.
- **That certificate must come from ACM (AWS Certificate Manager), and it
  must be requested in `us-east-1`**, regardless of which region the rest
  of your infrastructure lives in. This is a hard CloudFront requirement,
  not a preference.
- **ACM proves you own the domain before it issues the certificate.**
  The method used here is DNS validation: ACM gives you a random,
  per-certificate CNAME record to publish; once ACM can see that record
  resolve publicly, it considers ownership proven and issues the cert.
  (The alternative, email validation, isn't used here.)
- **A CNAME only works for a subdomain, never a bare apex domain**
  (`aiarap.com` itself can't be a CNAME per the DNS spec) — which is fine
  here since `dev.support.aiarap.com` is a subdomain.
- **This account has no Route53 hosted zone.** DNS for `aiarap.com` is
  managed externally at Hostinger. That means Terraform can create and
  validate the *certificate*, but every actual DNS record — both the ACM
  validation record and the final CNAME pointing the domain at
  CloudFront — has to be added by hand at Hostinger. In an account with a
  Route53 zone, Terraform could create both records itself
  (`aws_route53_record`) and the whole process would be one `apply` with
  no manual step at all.

## Step 1 — Request the ACM certificate (Terraform)

New file `terraform/shared/public_apps_domain.tf`:

```hcl
locals {
  spa_custom_domains = {
    react_support = "dev.support.aiarap.com"
  }
}

resource "aws_acm_certificate" "spa" {
  for_each          = local.spa_custom_domains
  domain_name       = each.value
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}
```

`for_each` over a map (rather than a single resource) is what makes this
reusable — adding a second custom domain later is just one more line in
`spa_custom_domains`, not a copy-pasted resource block.

Applied with a *targeted* plan/apply (`-target='aws_acm_certificate.spa'`)
rather than a full apply — deliberately, so this step only creates the
certificate and touches nothing else, since the certificate isn't usable
by anything downstream yet anyway.

```
terraform plan -target='aws_acm_certificate.spa' -out=acm.tfplan
terraform apply acm.tfplan
```

Result: a certificate in AWS with status `PENDING_VALIDATION`.

## Step 2 — Get the validation record and publish it

An output was added to surface the exact record ACM wants:

```hcl
output "spa_acm_validation_records" {
  value = {
    for k, cert in aws_acm_certificate.spa : k => {
      name  = tolist(cert.domain_validation_options)[0].resource_record_name
      type  = tolist(cert.domain_validation_options)[0].resource_record_type
      value = tolist(cert.domain_validation_options)[0].resource_record_value
    }
  }
}
```

For this cert, that was:

| Type | Name | Value |
|---|---|---|
| CNAME | `_23b0c2990a3d1b67d746704435c6990b.dev.support.aiarap.com.` | `_80e0ff99c5781f4f3fc0267ce01211f3.jkddzztszm.acm-validations.aws.` |

This was added manually as a CNAME record at Hostinger. This record has
nothing to do with where the app is hosted — it exists purely to prove
domain ownership to ACM, and can be left in place indefinitely afterward.

**Verifying it before trusting ACM to notice**: rather than guessing
whether it had propagated, the record was queried directly against two
independent public resolvers:

```
nslookup -type=CNAME _23b0c2990a3d1b67d746704435c6990b.dev.support.aiarap.com 8.8.8.8
nslookup -type=CNAME _23b0c2990a3d1b67d746704435c6990b.dev.support.aiarap.com 1.1.1.1
```

Both returned the expected target, confirming the record was correct and
live *before* asking ACM to validate — cheaper to check than to wait on
ACM only to find a typo.

## Step 3 — Complete validation (Terraform)

```hcl
resource "aws_acm_certificate_validation" "spa" {
  for_each                = local.spa_custom_domains
  certificate_arn         = aws_acm_certificate.spa[each.key].arn
  validation_record_fqdns = [tolist(aws_acm_certificate.spa[each.key].domain_validation_options)[0].resource_record_name]
}
```

This resource is special: `terraform apply` on it doesn't just create
something, it **blocks and polls ACM** until ACM itself confirms the DNS
record is visible and marks the certificate `ISSUED`. If the record isn't
there yet, this step just waits (up to Terraform's timeout) rather than
failing outright — so there's no harm running it slightly early, but
confirming propagation first (Step 2) avoids a long wait.

```
terraform apply -target='aws_acm_certificate_validation.spa' -auto-approve
```

Took a few minutes; came back `Apply complete! Resources: 1 added`.
`aws acm describe-certificate` afterward showed `Status: ISSUED`.

## Step 4 — Attach the cert + alias to the CloudFront distribution

Two edits to the existing `aws_cloudfront_distribution.spa` resource in
`public_apps.tf`:

```hcl
aliases = contains(keys(local.spa_custom_domains), each.key) ? [local.spa_custom_domains[each.key]] : []

viewer_certificate {
  cloudfront_default_certificate = contains(keys(local.spa_custom_domains), each.key) ? null : true
  acm_certificate_arn            = contains(keys(local.spa_custom_domains), each.key) ? aws_acm_certificate_validation.spa[each.key].certificate_arn : null
  ssl_support_method             = contains(keys(local.spa_custom_domains), each.key) ? "sni-only" : null
  minimum_protocol_version       = contains(keys(local.spa_custom_domains), each.key) ? "TLSv1.2_2021" : null
}
```

The `contains(keys(local.spa_custom_domains), each.key) ? ... : ...`
pattern is what lets one `for_each`-based resource serve **both**
react_support (which has a custom domain) and react_external (which
doesn't, and keeps CloudFront's default certificate/`*.cloudfront.net`
domain unchanged) — without duplicating the whole distribution resource
for the one app that needed a domain.

Two things unlocked here that aren't available on the default certificate:
- `minimum_protocol_version = "TLSv1.2_2021"` — the default CloudFront
  certificate is stuck at a `TLSv1` floor; a real ACM cert lets you raise it.
- `ssl_support_method = "sni-only"` — required whenever `acm_certificate_arn`
  is set (CloudFront's older non-SNI method exists but costs extra and
  isn't needed by any modern browser).

Note `certificate_arn` is read from `aws_acm_certificate_validation.spa`,
not `aws_acm_certificate.spa` — Terraform won't let the distribution use
the cert until the validation resource confirms it's actually `ISSUED`,
which naturally sequences the apply order correctly (distribution update
can't run before validation completes).

Planned and applied the same way as before — full `terraform plan`, review
the diff (it showed a clean 4-resource in-place update, 0 destroy: the
distribution itself, plus two IAM/S3-policy data sources that got
recomputed as a side-effect but whose actual content didn't change), then
`terraform apply <planfile>`. This step is a real CloudFront config
redeploy and took ~3 minutes to reach `Deployed`.

## Step 5 — Point the domain at CloudFront (final DNS record)

Once the distribution had the alias and cert attached, its own domain name
became the target for the *real* CNAME:

| Type | Name | Value |
|---|---|---|
| CNAME | `dev.support.aiarap.com` | `d3lb1wndc1hiqd.cloudfront.net` |

Also added manually at Hostinger (same reason as Step 2 — no Route53
zone). This is the record that actually makes the app reachable at the
custom domain; the Step 2 record only ever mattered to ACM.

## Step 6 — Verify end-to-end

Checked, in order, rather than assuming success from "the terraform apply
didn't error":

1. **DNS** — `nslookup -type=CNAME dev.support.aiarap.com` against two
   independent public resolvers, confirming it points at the CloudFront
   domain.
2. **Certificate** — `openssl s_client ... | openssl x509 -noout -subject
   -issuer -dates -ext subjectAltName` to confirm the cert actually served
   has the right CN/SAN, is ACM-issued, and isn't expired.
3. **TLS version** — same `openssl s_client` output's `Protocol:` line,
   confirming a modern TLS version actually negotiates (not just that the
   config *says* `TLSv1.2_2021`).
4. **HTTPS + redirect** — `curl -I http://dev.support.aiarap.com/` to
   confirm the plain-HTTP request gets a `301` to HTTPS, not served in the
   clear.
5. **SPA routing** — requested a made-up client-side path
   (`/some/nonexistent/client-route`) and confirmed it comes back `200`
   (the CloudFront custom-error-response → `/index.html` fallback still
   works on the new hostname, not just the old `.cloudfront.net` one).
6. **Security headers** — `curl -I` and grep for
   `Strict-Transport-Security`/`X-Frame-Options`/`Content-Security-Policy`/etc.
7. **Caching** — fetched an actual hashed asset path out of the served
   `index.html`, then checked its `Cache-Control`/`X-Cache` headers versus
   `index.html`'s, confirming the two-tier caching strategy applies on this
   hostname too.
8. **WAF** — confirmed via `aws cloudfront get-distribution` that the
   `WebACLId` on this distribution is the shared `spa-baseline` ACL, then
   used `aws wafv2 get-sampled-requests` filtered to a recent time window
   to see this domain's actual traffic being evaluated (`Action: ALLOW`
   for the benign verification requests) — proof the WAF is genuinely in
   the request path, not just referenced in config.

Every check passed; no further changes were needed.

## To repeat this for another domain/app

1. Add one line to `local.spa_custom_domains` in `public_apps_domain.tf`
   (e.g. `react_external = "dev.portal.aiarap.com"`).
2. `terraform apply -target='aws_acm_certificate.spa'`, read the new
   validation record from `spa_acm_validation_records`, add it at Hostinger.
3. Confirm it resolves via `nslookup` against 8.8.8.8/1.1.1.1.
4. `terraform apply -target='aws_acm_certificate_validation.spa'` (waits
   for ACM).
5. `terraform plan` / `terraform apply` (no `-target` needed — this picks
   up the distribution's `aliases`/`viewer_certificate` change for the new
   app automatically, since both are already written generically against
   `local.spa_custom_domains`).
6. Add the final CNAME (new domain → that app's CloudFront domain name,
   from the `spa_custom_domain_targets` output) at Hostinger.
7. Re-run the same 8-point verification as Step 6 above against the new
   hostname.

## Gotchas encountered worth remembering

- `terraform apply` (even a clean, non-destructive one) can get blocked by
  this environment's own tooling classifier — when that happens, the
  workaround was to hand the exact saved plan file to the user to apply
  from an independent terminal, not to bypass it.
- Don't skip the manual `nslookup` propagation check before running
  `aws_acm_certificate_validation` — it doesn't fail fast on a missing
  record, it just polls/waits, so a typo'd record produces a long stall
  rather than an immediate clear error.
- `viewer_certificate`'s four arguments (`cloudfront_default_certificate`,
  `acm_certificate_arn`, `ssl_support_method`, `minimum_protocol_version`)
  are mutually exclusive as a group — CloudFront rejects a config that sets
  both `cloudfront_default_certificate = true` and an `acm_certificate_arn`
  at the same time. The `contains(...) ? ... : null` pattern above is what
  keeps them cleanly either/or per app.
