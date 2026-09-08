# Cognito app clients for the two public portal apps (ADR-0038) — the
# backend auth half of what public_apps.tf's S3/CloudFront/ACM stood up. The
# two new scopes themselves live on aws_cognito_resource_server.node
# (cognito.tf), since Cognito requires every scope for a resource server
# declared on that one resource block.
#
# One app client per (app, environment) — 6 total — same per-environment
# isolation modules/tenant-onboarding already gives the M2M connections: a
# leaked dev client can't touch qa/prod.
locals {
  public_app_clients = merge(
    {
      for env, domain in module.portal_app.domain_names :
      "portal-${env}" => { app = "portal", env = env, domain = domain, scope = "node.portal.${env}" }
    },
    {
      for env, domain in module.support_app.domain_names :
      "support-${env}" => { app = "support", env = env, domain = domain, scope = "node.support.${env}" }
    },
  )
}

# Public client (no secret), Authorization Code + PKCE — the only OAuth flow
# a browser SPA can use safely. Unlike the M2M connections'
# client_credentials + secret (modules/tenant-onboarding/cognito.tf), a human
# is present at login time and PKCE replaces the secret as proof the token
# request came from the same client that started the flow.
resource "aws_cognito_user_pool_client" "public_app" {
  for_each = local.public_app_clients

  name         = "${each.value.app}-${each.value.env}"
  user_pool_id = aws_cognito_user_pool.shared.id

  generate_secret = false

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes = [
    "openid",
    "email",
    "profile",
    "${aws_cognito_resource_server.node.identifier}/${each.value.scope}",
  ]
  supported_identity_providers = ["COGNITO"]

  # Convention, not yet confirmed against either app's own router — both
  # React apps are assumed to handle the OAuth redirect at /callback and
  # post-logout at their root. Verify once the apps' actual auth code exists
  # (open item, ADR-0038/parking lot).
  callback_urls = ["https://${each.value.domain}/callback"]
  logout_urls   = ["https://${each.value.domain}/"]

  # Matters specifically for a public client — don't leak "this user exists"
  # via distinct error messages to an unauthenticated caller.
  prevent_user_existence_errors = "ENABLED"
}
