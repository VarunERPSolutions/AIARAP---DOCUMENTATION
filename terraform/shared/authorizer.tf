locals {
  # Which of the 9 provisioned pools the authorizer actually trusts right
  # now. All 9 pools/resource servers exist (cognito.tf) regardless of this
  # list — this is deliberately narrower, scoping down to only the pools
  # that also have a real app client (public_apps_cognito.tf) wired up.
  # Extend this list (and add the matching app client) when qa/prd or the
  # syscomms pools go live — nothing else about cognito.tf needs to change.
  active_pool_keys = ["support-dev", "portal-dev"]

  # The authorizer's full trust allowlist, keyed by Cognito pool ID. This IS
  # what makes multi-pool verification safe (ADR-0040): the Lambda only ever
  # builds a verifier for a pool ID that appears here, which only ever
  # contains pool IDs Terraform itself just created — a token's unverified
  # `iss` can select among these, never add to them. Filtered to
  # local.active_pool_keys, so a token somehow obtained against one of the
  # 7 inactive pools still wouldn't be trusted here even if it existed.
  cognito_pool_map = {
    for key, pool in aws_cognito_user_pool.app : pool.id => {
      group = local.cognito_pools[key].group
      env   = local.cognito_pools[key].env
    }
    if contains(local.active_pool_keys, key)
  }
}

module "authorizer" {
  source = "../modules/lambda-authorizer"

  reserved_concurrent_executions = var.authorizer_reserved_concurrency

  # apiId -> backend name. Environment is resolved from requestContext.stage
  # inside the authorizer, same as before.
  api_backend_map = {
    for key in local.backends : aws_api_gateway_rest_api.this[key].id => key
  }

  # Additive only (ADR-0041, sandcastle_cognito.tf) — the 4 Sandcastle lane
  # pools are trusted alongside the 2 real active pools, never replacing or
  # narrowing them. Each lane pool's env is "sandcastle-N", never "dev"/
  # "qa"/"prd", so it can only ever authenticate against that lane's own
  # API Gateway stage (sandcastle.tf) — see that file's header comment.
  pool_map = merge(local.cognito_pool_map, local.sandcastle_pool_map)
}

resource "aws_api_gateway_authorizer" "this" {
  for_each = local.backends

  name                             = "varunerp-authorizer"
  rest_api_id                      = aws_api_gateway_rest_api.this[each.key].id
  type                             = "REQUEST"
  authorizer_uri                   = module.authorizer.invoke_arn
  identity_source                  = "method.request.header.Authorization"
  authorizer_result_ttl_in_seconds = 0
}

resource "aws_lambda_permission" "apigw" {
  for_each      = local.backends
  statement_id  = "AllowAPIGatewayInvoke-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = module.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this[each.key].execution_arn}/authorizers/${aws_api_gateway_authorizer.this[each.key].id}"
}
