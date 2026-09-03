# Governance/audit trail — Cognito app clients and API keys aren't taggable,
# so the pg-inventory-writer's tables are the source of truth for "who owns
# which credential." Terraform has no VPC reachability to aiarap RDS
# directly, so this goes through the shared writer Lambda instead of an
# in-provider Postgres resource.
#
# lifecycle_scope = "CRUD" re-invokes on update, and invokes once more with
# tf.action = "delete" (carrying the last input as tf.prev_input) when a
# connection is removed from var.connections/var.environments — mirroring
# aws_dynamodb_table_item's create/update/delete-on-destroy behavior.
resource "aws_lambda_invocation" "conn_inventory" {
  for_each = var.enable_inventory ? local.connection_envs : {}

  function_name   = var.inventory_writer_function_name
  lifecycle_scope = "CRUD"

  input = jsonencode({
    connection_id     = "${var.customer_id}-${each.value.conn_key}-${each.value.env}"
    customer          = var.customer_id
    connection_key    = each.value.conn_key
    backend           = each.value.backend
    environment       = each.value.env
    cognito_client_id = aws_cognito_user_pool_client.conn[each.key].id
    api_key_id        = aws_api_gateway_api_key.conn[each.key].id
    usage_plan_id     = aws_api_gateway_usage_plan.conn[each.key].id
    secret_arn        = aws_secretsmanager_secret.conn[each.key].arn
    status            = "active"
  })
}
