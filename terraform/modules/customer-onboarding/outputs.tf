output "connections" {
  description = "Map of connection key (\"<conn>-<env>\") -> identifiers, for reference/inventory."
  sensitive   = true
  value = {
    for k, v in local.connection_envs : k => {
      cognito_client_id = aws_cognito_user_pool_client.conn[k].id
      secret_arn        = aws_secretsmanager_secret.conn[k].arn
      api_key_id        = aws_api_gateway_api_key.conn[k].id
      usage_plan_id     = aws_api_gateway_usage_plan.conn[k].id
      scope             = v.scope
      host              = local.env_domain_name[v.env]
      path              = "/${v.backend}"
    }
  }
}

output "env_domains" {
  description = "Map of environment -> public hostname for this customer (one domain object per environment now, not apex+wildcard)."
  value       = { for env, dn in aws_api_gateway_domain_name.env : env => dn.domain_name }
}
