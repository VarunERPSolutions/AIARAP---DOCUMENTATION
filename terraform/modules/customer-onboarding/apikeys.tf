# API key + usage plan per connection. The key is NOT the auth mechanism (the
# OAuth token is) — it exists purely so each connection gets its own
# independently-tunable rate limit/quota and shows up separately in metering.
resource "aws_api_gateway_api_key" "conn" {
  for_each = local.connection_envs
  name     = "${var.customer_id}-${each.value.conn_key}-${each.value.env}"
}

resource "aws_api_gateway_usage_plan" "conn" {
  for_each = local.connection_envs
  name     = "${var.customer_id}-${each.value.conn_key}-${each.value.env}"

  api_stages {
    api_id = var.api_ids[each.value.backend]
    stage  = each.value.env
  }

  throttle_settings {
    rate_limit  = try(var.throttle_overrides[each.key].rate_limit, var.default_throttle.rate_limit)
    burst_limit = try(var.throttle_overrides[each.key].burst_limit, var.default_throttle.burst_limit)
  }

  quota_settings {
    limit  = try(var.throttle_overrides[each.key].quota_limit, var.default_throttle.quota_limit)
    period = "DAY"
  }
}

resource "aws_api_gateway_usage_plan_key" "conn" {
  for_each      = local.connection_envs
  key_id        = aws_api_gateway_api_key.conn[each.key].id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.conn[each.key].id
}
