# App clients for react-external-app (portal) and react-support-app
# (support), DEV pools only. ADR-0038 always pointed at this filename for
# the per-app PKCE clients; it never actually existed until now.
#
# Scope, deliberately: only the 2 dev pools get a client here. All 9 pools
# (cognito.tf) exist as real Cognito resources — qa/prd for these two groups,
# and all 3 syscomms pools, are provisioned but have no app client, so
# nothing can authenticate against them yet. authorizer.tf's pool_map is
# separately scoped to just these 2 active pools, so even a stray token
# somehow obtained against an inactive pool wouldn't be trusted by the
# authorizer either — two independent reasons the other 7 stay inert.

locals {
  # ---------------------------------------------------------------------
  # TEMPORARY: callback_urls/logout_urls = root "/" for BOTH apps.
  # ---------------------------------------------------------------------
  # VERIFIED against each app's actual source (2026-09-09), not assumed:
  # neither AIARAP-external-app nor AIARAP-support-app has react-router (or
  # any router) in package.json; both are single static components with
  # inert "Sign in" buttons — no onClick, no OAuth handling of any kind. A
  # "/callback" path would have loaded fine (CloudFront's
  # custom_error_response already serves /index.html for any 403/404,
  # public_apps.tf) but nothing in either app would read the `code` query
  # param once there — so any path other than "/" would have been an
  # invented convention with nothing to receive it. Root "/" is deliberately
  # NOT assumed to be a real callback route either — it's just the only URL
  # that currently loads either app at all, used here as a placeholder.
  #
  # REQUIRED before this is real: each React app must implement the PKCE
  # authorization-code exchange ON PAGE LOAD — i.e., on every load of "/",
  # check for a `?code=...&state=...` query string (Cognito Hosted UI
  # appends this after login), and if present, exchange it at this pool's
  # `/oauth2/token` endpoint using the PKCE `code_verifier` stashed in
  # sessionStorage before the redirect to Hosted UI, then strip the query
  # string from the URL. Today, neither app does any of this — the Hosted
  # UI redirect would land back on "/" carrying an unused `code` param, and
  # the login would appear to silently do nothing. This is app-code work,
  # not Terraform; not built as part of this change.
  #
  # When that code exists (whether at "/" or a dedicated route), update
  # this file's callback_urls/logout_urls AND both apps' .env
  # VITE_COGNITO_CALLBACK_URL/VITE_COGNITO_LOGOUT_URL together — don't let
  # them drift out of sync with each other or with whatever path the app
  # code actually listens on.
  public_app_dev_hosts = {
    portal  = "d1gomc31u4b7fd.cloudfront.net" # react-external-app dev — no custom domain by design (ADR-0038 §4); confirmed via terraform.tfstate's aws_cloudfront_distribution.spa["react_external"]
    support = "dev.support.aiarap.com"        # react-support-app dev — confirmed live, CloudFront ED3ZDFZ1ZEW4Z
  }
}

resource "aws_cognito_user_pool_client" "public_app_dev" {
  for_each = local.public_app_dev_hosts

  name         = "react-${each.key == "portal" ? "external" : "support"}-app-dev"
  user_pool_id = aws_cognito_user_pool.app["${each.key}-dev"].id

  # Public client (browser SPA) — no secret, PKCE covers what a secret would.
  generate_secret = false

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes = [
    "openid", "email", "phone",
    "${aws_cognito_resource_server.app["${each.key}-dev-node"].identifier}/node.${each.key}"
  ]
  supported_identity_providers = ["COGNITO"]

  # Human login only — no client_credentials here, this is a public client.
  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_AUTH", "ALLOW_USER_SRP_AUTH"]

  callback_urls = ["https://${each.value}/"]
  logout_urls   = ["https://${each.value}/"]

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  # Same baseline as AIARAP_DEV's client (ADR-0040).
  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 5
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

output "public_app_dev_clients" {
  description = "Pool ID, client ID, and Hosted UI domain for each active dev app client — copy into the matching React app's .env (VITE_COGNITO_*) after apply."
  value = {
    for key, client in aws_cognito_user_pool_client.public_app_dev : key => {
      user_pool_id = aws_cognito_user_pool.app["${key}-dev"].id
      client_id    = client.id
      domain       = "${aws_cognito_user_pool_domain.app["${key}-dev"].domain}.auth.${data.aws_region.current.name}.amazoncognito.com"
      region       = data.aws_region.current.name
      # NOT client.callback_urls[0]/logout_urls[0] — the AWS provider types
      # these as set(string), and sets have no order to index into
      # (confirmed: "Invalid index" on a real terraform plan, 2026-09-09).
      # Reconstructed from the same local these resources built the URLs
      # from in the first place, rather than reading a set back apart.
      callback_url = "https://${local.public_app_dev_hosts[key]}/"
      logout_url   = "https://${local.public_app_dev_hosts[key]}/"
    }
  }
}
