# ---------------------------------------------------------------------------
# Cognito: 9 pools (ADR-0040) — one per (application category, environment).
# Supersedes the single shared `varunerp-integration-pool` + node/sap
# resource servers this file used to define (ADR-0038 §3, now superseded).
#
# Deliberately deferred, NOT part of this file:
# - Per-app-client provisioning (react-external-app/react-support-app's own
#   PKCE app clients) — already a documented gap before this change
#   (ADR-0038 pointed at a `public_apps_cognito.tf` that was never created);
#   still not created here. Per-Tenant M2M clients stay owned by
#   `modules/tenant-onboarding`, unaffected by this file.
# - Custom branded Hosted UI domains. The old shared pool's
#   `auth.varunerpsolutions.com` (ACM cert + manual Hostinger DNS, since this
#   account has no Route53 zone for either of its domains) is gone along
#   with the pool it belonged to. 9 pools would mean 9 ACM certs + 9 manual
#   DNS entries for a cosmetic Hosted-UI-branding win; each pool instead
#   gets Cognito's free built-in `<prefix>.auth.<region>.amazoncognito.com`
#   domain. Revisit only if Hosted UI branding on these specific pools'
#   login pages actually becomes a requirement.
# ---------------------------------------------------------------------------

locals {
  # group -> which backend(s) it may call, and the scope name it needs on
  # each. Scope names deliberately drop the "<env>" suffix ADR-0038 used
  # (e.g. "node.support.dev") — the pool itself now encodes environment, so
  # a second env marker on the scope string is redundant. "syscomms" is the
  # only group spanning two backends (node AND sap), since the M2M/"invoke"
  # concept it replaces was never Node-specific.
  cognito_groups = {
    support  = { scopes = { node = "node.support" } }
    portal   = { scopes = { node = "node.portal" } }
    syscomms = { scopes = { node = "node.invoke", sap = "sap.invoke" } }
  }

  cognito_environments = ["dev", "qa", "prd"]

  # 9 entries: {support,portal,syscomms} x {dev,qa,prd}.
  cognito_pools = {
    for pair in setproduct(keys(local.cognito_groups), local.cognito_environments) :
    "${pair[0]}-${pair[1]}" => { group = pair[0], env = pair[1] }
  }

  # One resource server per (pool, backend it's relevant to) — a syscomms
  # pool gets both a node-api and a sap-api resource server; a support/
  # portal pool gets only node-api. Flattened via merge(...[for...]...) into
  # a single for_each-able map.
  cognito_resource_servers = merge([
    for pool_key, pool in local.cognito_pools : {
      for backend, scope_name in local.cognito_groups[pool.group].scopes :
      "${pool_key}-${backend}" => {
        pool_key    = pool_key
        backend     = backend
        scope_name  = scope_name
        identifier  = backend == "node" ? "https://api.aiarap.com/node" : "https://api.varunerpsolutions.com/sap"
        server_name = "${backend}-api"
      }
    }
  ]...)
}

# Baseline settings below carried over from the existing AIARAP_DEV pool
# (us-east-1_2iggcQC6h) per ADR-0040 — inspected via `aws cognito-idp
# describe-user-pool` (2026-09-09), NOT imported or referenced by ID.
# AIARAP_DEV itself is untouched by this file — every resource below is a
# brand-new pool.
resource "aws_cognito_user_pool" "app" {
  for_each = local.cognito_pools

  name = "varunerp-${each.value.group}-${each.value.env}-pool"

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
    recovery_mechanism {
      name     = "verified_phone_number"
      priority = 2
    }
  }

  deletion_protection = "ACTIVE"

  # OFF for every pool, matching AIARAP_DEV's baseline — including the 3 prd
  # pools. ADR-0040 flags this as an open item worth an explicit decision
  # for production rather than a silent carry-over; not resolved here.
  mfa_configuration = "OFF"
}

resource "aws_cognito_user_pool_domain" "app" {
  for_each     = local.cognito_pools
  domain       = "varunerp-${each.value.group}-${each.value.env}"
  user_pool_id = aws_cognito_user_pool.app[each.key].id
}

resource "aws_cognito_resource_server" "app" {
  for_each     = local.cognito_resource_servers
  identifier   = each.value.identifier
  name         = each.value.server_name
  user_pool_id = aws_cognito_user_pool.app[each.value.pool_key].id

  scope {
    scope_name        = each.value.scope_name
    scope_description = "${each.value.scope_name} — ${local.cognito_pools[each.value.pool_key].group}, ${local.cognito_pools[each.value.pool_key].env}"
  }
}

output "cognito_pool_ids" {
  description = "Pool ID per (group, env) key (e.g. \"support-dev\"). Feeds authorizer.tf's pool_map and, later, per-pool app client provisioning."
  value       = { for k, v in aws_cognito_user_pool.app : k => v.id }
}

output "cognito_pool_domains" {
  description = "Built-in Hosted UI domain per pool."
  value       = { for k, v in aws_cognito_user_pool_domain.app : k => "${v.domain}.auth.${data.aws_region.current.name}.amazoncognito.com" }
}

data "aws_region" "current" {}
