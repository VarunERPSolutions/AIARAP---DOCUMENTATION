module "authorizer" {
  source = "../modules/lambda-authorizer"

  cognito_user_pool_id           = aws_cognito_user_pool.shared.id
  reserved_concurrent_executions = var.authorizer_reserved_concurrency

  # apiId -> backend name. Environment is no longer resolved here at all —
  # it comes straight from requestContext.stage inside the authorizer.
  api_backend_map = {
    for key in local.backends : aws_api_gateway_rest_api.this[key].id => key
  }
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
