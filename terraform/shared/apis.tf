# One REST API per backend. Resources/methods/integrations are identical
# across environments — only the stage differs, and each stage supplies its
# own `gwPort` stage variable that the integration URI resolves at request
# time. That's what lets 3 REST APIs serve 8 (backend, environment) pairs
# instead of needing one API per pair.
resource "aws_api_gateway_rest_api" "this" {
  for_each = local.backends
  name     = "varunerp-${each.key}-api"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "proxy" {
  for_each    = local.backends
  rest_api_id = aws_api_gateway_rest_api.this[each.key].id
  parent_id   = aws_api_gateway_rest_api.this[each.key].root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "root_any" {
  for_each      = local.backends
  rest_api_id   = aws_api_gateway_rest_api.this[each.key].id
  resource_id   = aws_api_gateway_rest_api.this[each.key].root_resource_id
  http_method   = "ANY"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.this[each.key].id
}

resource "aws_api_gateway_method" "proxy_any" {
  for_each      = local.backends
  rest_api_id   = aws_api_gateway_rest_api.this[each.key].id
  resource_id   = aws_api_gateway_resource.proxy[each.key].id
  http_method   = "ANY"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.this[each.key].id

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

# NOTE the $${stageVariables.gwPort} escaping: the outer ${...} is resolved
# by Terraform (the NLB's DNS name); the doubled $$ produces a literal
# ${stageVariables.gwPort} in the stored integration config, which API
# Gateway itself resolves per-request from whichever stage handled the call.
resource "aws_api_gateway_integration" "root" {
  for_each                = local.backends
  rest_api_id             = aws_api_gateway_rest_api.this[each.key].id
  resource_id             = aws_api_gateway_rest_api.this[each.key].root_resource_id
  http_method             = aws_api_gateway_method.root_any[each.key].http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.this.id
  uri                     = "http://${aws_lb.internal.dns_name}:$${stageVariables.gwPort}/"
}

resource "aws_api_gateway_integration" "proxy" {
  for_each                = local.backends
  rest_api_id             = aws_api_gateway_rest_api.this[each.key].id
  resource_id             = aws_api_gateway_resource.proxy[each.key].id
  http_method             = aws_api_gateway_method.proxy_any[each.key].http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.this.id
  uri                     = "http://${aws_lb.internal.dns_name}:$${stageVariables.gwPort}/{proxy}"

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

# One deployment per backend (a snapshot of resources/methods/integrations,
# identical across its environments) — NOT one per environment. The
# per-environment split happens entirely at the stage below.
resource "aws_api_gateway_deployment" "this" {
  for_each    = local.backends
  rest_api_id = aws_api_gateway_rest_api.this[each.key].id

  triggers = {
    redeploy_hash = sha1(jsonencode([
      aws_api_gateway_method.root_any[each.key].id,
      aws_api_gateway_method.proxy_any[each.key].id,
      aws_api_gateway_integration.root[each.key].id,
      aws_api_gateway_integration.proxy[each.key].id,
      aws_api_gateway_authorizer.this[each.key].id,
      aws_api_gateway_method.proxy_options[each.key].id,
      aws_api_gateway_integration.proxy_options[each.key].id,
      aws_api_gateway_integration_response.proxy_options[each.key].id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.root,
    aws_api_gateway_integration.proxy,
    aws_api_gateway_integration_response.proxy_options,
  ]
}

# One stage per (backend, environment) — 8 today (3 node + 3 java... well,
# however many entries are actually in each *_environments map — see
# local.backend_envs). Stage name = environment name by convention; that's
# what lets the Lambda authorizer read environment straight off
# requestContext.stage instead of parsing anything.
resource "aws_api_gateway_stage" "this" {
  for_each      = local.backend_envs
  rest_api_id   = aws_api_gateway_rest_api.this[each.value.backend].id
  deployment_id = aws_api_gateway_deployment.this[each.value.backend].id
  stage_name    = each.value.env

  variables = {
    gwPort = tostring(each.value.port)
  }
}
