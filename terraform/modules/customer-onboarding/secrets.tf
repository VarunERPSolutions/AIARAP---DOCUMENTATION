# One secret per connection, handed to the customer once over a secure channel.
# Bundles everything their system needs to call in: token endpoint, client
# credentials, scope, and the exact host/path to call.
resource "aws_secretsmanager_secret" "conn" {
  for_each = local.connection_envs
  name     = "varunerp/customers/${var.customer_id}/${each.value.conn_key}/${each.value.env}"
}

resource "aws_secretsmanager_secret_version" "conn" {
  for_each  = local.connection_envs
  secret_id = aws_secretsmanager_secret.conn[each.key].id

  secret_string = jsonencode({
    client_id     = aws_cognito_user_pool_client.conn[each.key].id
    client_secret = aws_cognito_user_pool_client.conn[each.key].client_secret
    token_url     = "https://${var.cognito_domain}/oauth2/token"
    scope         = "${var.resource_server_identifiers[each.value.backend]}/${each.value.scope}"
    api_key       = aws_api_gateway_api_key.conn[each.key].value
    api_host      = each.value.is_prod ? "${var.customer_id}.${var.base_domain}" : "${each.value.env}.${var.customer_id}.${var.base_domain}"
    api_path      = "/${each.value.backend}"
  })
}
