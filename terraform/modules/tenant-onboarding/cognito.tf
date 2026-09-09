# One app client per connection x environment. Scope is restricted to exactly
# the one backend+env this client is allowed to call — this is the actual
# per-Tenant-per-backend-per-environment isolation boundary.
resource "aws_cognito_user_pool_client" "conn" {
  for_each = local.connection_envs

  name         = "${var.subdomain}-${each.value.conn_key}-${each.value.env}"
  user_pool_id = var.cognito_user_pool_ids[each.value.env]

  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes = [
    "${var.resource_server_identifiers[each.value.backend]}/${each.value.scope}"
  ]
  supported_identity_providers = ["COGNITO"]

  access_token_validity = var.access_token_validity_hours
  token_validity_units {
    access_token = "hours"
  }
}
