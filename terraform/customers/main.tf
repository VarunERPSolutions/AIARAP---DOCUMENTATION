module "customer" {
  for_each = var.customers
  source   = "../modules/customer-onboarding"

  customer_id     = each.key
  route53_zone_id = var.route53_zone_id

  cognito_user_pool_id           = var.cognito_user_pool_id
  api_ids                        = var.api_ids
  inventory_writer_function_name = var.inventory_writer_function_name

  environments       = each.value.environments
  connections        = each.value.connections
  throttle_overrides = each.value.throttle_overrides
}

output "customer_connections" {
  sensitive = true
  value     = { for k, m in module.customer : k => m.connections }
}
