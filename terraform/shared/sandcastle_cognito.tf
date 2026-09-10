# Cognito piece of the Sandcastle E2E lane pool (sandcastle.tf, ADR-0041).
#
# Deliberately NOT part of cognito.tf's `local.cognito_pools` 3x3 setproduct
# — that would also generate unwanted support-sandcastle-N/portal-sandcastle-N
# pools (only syscomms needs a lane identity). Kept as fully separate
# resources instead, reusing cognito.tf's `local.cognito_groups.syscomms`
# scope definition ("node.invoke") rather than redefining it, so a future
# change to that scope name only has one place to edit.
#
# Why a dedicated pool per lane, not the existing syscomms-dev pool: the
# real deployed authorizer (verified by downloading and reading its actual
# code, 2026-09-10) requires `pool.env === requestContext.stage` exactly —
# a syscomms-dev token (env="dev") would be denied against a "sandcastle-N"
# stage. Each lane's pool therefore has its own env="sandcastle-N", matching
# its own dedicated API Gateway stage of the same name (sandcastle.tf).
#
# No Lambda authorizer CODE change needed — "syscomms" and "node.invoke"
# already exist in the deployed Lambda's hardcoded GROUP_SCOPES. Only
# authorizer.tf's pool_map needs to additively trust these 4 new pool IDs
# (one-line merge() change there).

resource "aws_cognito_user_pool" "sandcastle_lane" {
  for_each = local.sandcastle_lane_ports

  name = "varunerp-syscomms-sandcastle-${each.key}-pool"

  # Same baseline as cognito.tf's aws_cognito_user_pool.app — see that
  # file's header comment for where these values came from.
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

  # Not ACTIVE, unlike cognito.tf's real pools — these are ephemeral-purpose
  # test pools; skip the same protection real environment pools need.
  deletion_protection = "INACTIVE"

  mfa_configuration = "OFF"
}

resource "aws_cognito_user_pool_domain" "sandcastle_lane" {
  for_each = local.sandcastle_lane_ports

  domain       = "varunerp-syscomms-sandcastle-${each.key}"
  user_pool_id = aws_cognito_user_pool.sandcastle_lane[each.key].id
}

resource "aws_cognito_resource_server" "sandcastle_lane_node" {
  for_each = local.sandcastle_lane_ports

  identifier   = "https://api.aiarap.com/node"
  name         = "node-api"
  user_pool_id = aws_cognito_user_pool.sandcastle_lane[each.key].id

  scope {
    scope_name        = local.cognito_groups.syscomms.scopes.node # "node.invoke" — reused, not redefined
    scope_description = "node.invoke — syscomms, sandcastle-${each.key}"
  }
}

# M2M client_credentials client — unlike public_apps_cognito.tf's PKCE public
# clients, this one generates a secret and never touches a browser.
resource "aws_cognito_user_pool_client" "sandcastle_lane" {
  for_each = local.sandcastle_lane_ports

  name         = "sandcastle-lane-${each.key}"
  user_pool_id = aws_cognito_user_pool.sandcastle_lane[each.key].id

  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes = [
    "${aws_cognito_resource_server.sandcastle_lane_node[each.key].identifier}/${local.cognito_groups.syscomms.scopes.node}"
  ]
  supported_identity_providers = ["COGNITO"]

  # M2M only — no user-facing auth flow needed, unlike public_app_dev.
  explicit_auth_flows = []

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  # No id/refresh token needed for client_credentials — access token only.
  access_token_validity = 60
  token_validity_units {
    access_token = "minutes"
  }
}

locals {
  # Merged into authorizer.tf's pool_map (additive only — see that file).
  sandcastle_pool_map = {
    for key, pool in aws_cognito_user_pool.sandcastle_lane : pool.id => {
      group = "syscomms"
      env   = "sandcastle-${key}"
    }
  }
}

output "sandcastle_lane_credentials" {
  description = "Client ID/secret + token endpoint per lane — the orchestrator mints a client_credentials token from these before each run. Client secret is sensitive; not printed by a bare `terraform output`."
  sensitive = true
  value = {
    for key, client in aws_cognito_user_pool_client.sandcastle_lane : key => {
      user_pool_id  = aws_cognito_user_pool.sandcastle_lane[key].id
      client_id     = client.id
      client_secret = client.client_secret
      token_url     = "https://${aws_cognito_user_pool_domain.sandcastle_lane[key].domain}.auth.${data.aws_region.current.name}.amazoncognito.com/oauth2/token"
      scope         = "${aws_cognito_resource_server.sandcastle_lane_node[key].identifier}/${local.cognito_groups.syscomms.scopes.node}"
    }
  }
}
