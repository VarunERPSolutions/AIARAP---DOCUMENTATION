module "tenant" {
  for_each = var.tenants
  source   = "../modules/tenant-onboarding"

  subdomain       = each.key
  route53_zone_id = var.route53_zone_id

  cognito_user_pool_ids          = var.cognito_user_pool_ids
  cognito_domains                = var.cognito_domains
  api_ids                        = var.api_ids
  inventory_writer_function_name = var.inventory_writer_function_name

  environments       = each.value.environments
  connections        = each.value.connections
  throttle_overrides = each.value.throttle_overrides
}

output "tenant_connections" {
  sensitive = true
  value     = { for k, m in module.tenant : k => m.connections }
}
