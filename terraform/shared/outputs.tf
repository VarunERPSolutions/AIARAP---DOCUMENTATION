output "api_ids" {
  description = "Feed this straight into customers/variables.tf's api_ids. One ID per backend — dev/qa/prd are stages of it, not separate APIs."
  value = {
    node = aws_api_gateway_rest_api.this["node"].id
    java = aws_api_gateway_rest_api.this["java"].id
  }
}

output "sap_api_id" {
  description = "The single sap REST API ID — dev/prd are stages of it."
  value       = aws_api_gateway_rest_api.this["sap"].id
}

output "sap_api_domains" {
  description = "Public hostname per provisioned SAP environment."
  value = {
    for env in keys(var.sap_environments) : env => aws_api_gateway_domain_name.sap[env].domain_name
  }
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.shared.id
}

output "cognito_domain" {
  value = aws_cognito_user_pool_domain.auth.domain
}

output "inventory_writer_function_name" {
  description = "Feed this into customers/variables.tf's inventory_writer_function_name."
  value       = module.pg_writer.function_name
}

output "flow2_secret_arns" {
  description = "Secrets Manager ARN per provisioned SAP environment, holding VarunERP's own Salesforce->SAP OAuth credentials."
  value = {
    for env in local.flow2_envs : env => aws_secretsmanager_secret.varunerp_sf_sap[env].arn
  }
}
