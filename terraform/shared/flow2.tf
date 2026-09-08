# Flow 2: VarunERP's own Salesforce -> VarunERP's own SAP. Doesn't fit
# modules/tenant-onboarding (that's shaped for external Tenants on
# aiarap.com); this is a single internal relationship on varunerpsolutions.com,
# so it's wired directly here. One connection per provisioned SAP
# environment — VarunERP Salesforce also has dev/prod instances, matching
# SAP's dev/prod split.
locals {
  flow2_envs = toset(keys(var.sap_environments)) # add "prd" here automatically once sap_environments includes it
}

resource "aws_cognito_user_pool_client" "varunerp_sf_sap" {
  for_each = local.flow2_envs

  name         = "varunerp-sf-sap-${each.key}"
  user_pool_id = aws_cognito_user_pool.shared.id

  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes = [
    "${aws_cognito_resource_server.sap.identifier}/sap.invoke.${each.key}"
  ]
  supported_identity_providers = ["COGNITO"]

  access_token_validity = 1
  token_validity_units {
    access_token = "hours"
  }
}

resource "aws_secretsmanager_secret" "varunerp_sf_sap" {
  for_each = local.flow2_envs
  name     = "varunerp/internal/sf-sap/${each.key}"
}

resource "aws_secretsmanager_secret_version" "varunerp_sf_sap" {
  for_each  = local.flow2_envs
  secret_id = aws_secretsmanager_secret.varunerp_sf_sap[each.key].id

  secret_string = jsonencode({
    client_id     = aws_cognito_user_pool_client.varunerp_sf_sap[each.key].id
    client_secret = aws_cognito_user_pool_client.varunerp_sf_sap[each.key].client_secret
    token_url     = "https://${aws_cognito_user_pool_domain.auth.domain}/oauth2/token"
    scope         = "${aws_cognito_resource_server.sap.identifier}/sap.invoke.${each.key}"
    api_host      = aws_api_gateway_domain_name.sap[each.key].domain_name
  })
}
