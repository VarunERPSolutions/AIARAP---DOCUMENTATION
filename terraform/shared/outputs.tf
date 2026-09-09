output "api_ids" {
  description = "Feed this straight into tenants/variables.tf's api_ids. One ID per backend — dev/qa/prd are stages of it, not separate APIs. No \"java\" entry — Java has no inbound API (ADR-0039); see java_outbound.tf."
  value = {
    node = aws_api_gateway_rest_api.this["node"].id
  }
}

output "java_batch_complete_queue_url" {
  description = "SQS queue URL Java publishes to on completing a nightly extraction run; NestJS consumes from here."
  value       = aws_sqs_queue.batch_complete.url
}

output "java_outbound_policy_arn" {
  description = "Attach to java-app's instance role (or pass java_app_iam_role_name to have this stack attach it directly) — grants outbound Tenant SAP secret read + batch-complete publish."
  value       = aws_iam_policy.java_outbound.arn
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

# cognito_user_pool_id / cognito_domain (singular) removed — ADR-0040
# replaced the single shared pool with 9. See cognito_pool_ids /
# cognito_pool_domains outputs in cognito.tf instead.

# inventory_writer_function_name removed (2026-09-09) — moved along with
# the rest of the pg-inventory-writer concern to terraform/inventory/,
# which now produces this output itself.

output "flow2_secret_arns" {
  description = "Secrets Manager ARN per provisioned SAP environment, holding VarunERP's own Salesforce->SAP OAuth credentials."
  value = {
    for env in local.flow2_envs : env => aws_secretsmanager_secret.varunerp_sf_sap[env].arn
  }
}

# portal/support app hosting outputs deliberately NOT restored here — the
# spa-hosting module (module.portal_app/module.support_app) they referenced
# is superseded by the S3+CloudFront+WAF design in public_apps.tf, which
# already exposes the same information as spa_bucket_names/
# spa_distribution_ids/spa_distribution_domain_names.
