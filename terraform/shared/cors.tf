# CORS for browser callers of the REST APIs (apis.tf). Two independent gaps,
# confirmed live on 2026-09-10 against the real node API (hn0omem2c0):
#
# 1. The {proxy+} resource (apis.tf) only has an ANY method behind CUSTOM
#    (Lambda) authorization — there was never an OPTIONS method, so a
#    preflight request had no method to match at all. (A prior session
#    applied an OPTIONS/MOCK fix directly against AWS without ever
#    committing the .tf for it — this file replaces that with the real,
#    tracked version, so the two no longer drift apart.)
# 2. Even with (1) fixed, a request the Lambda authorizer denies (missing
#    token -> 401 UNAUTHORIZED, invalid/rejected token -> 403 ACCESS_DENIED)
#    never reaches the OPTIONS integration or the backend's own CORS
#    handling at all — API Gateway generates its own Gateway Response for
#    both cases, which by default carries no CORS headers whatsoever. The
#    browser reports this as a CORS error, masking the real 401/403.
#    Confirmed live: `curl` showed OPTIONS returning correct CORS headers,
#    but an unauthenticated GET returned a bare 401 with none.
#
# Access-Control-Allow-Origin is "*", not an explicit origin allowlist: every
# caller here authenticates via the Authorization header only (see
# AIARAP-support-app's src/api/me.ts) — none use `credentials: 'include'` —
# and CORS only restricts wildcard origins when a request carries
# credentials (cookies), so "*" is safe and also avoids hardcoding this to
# one app's origin while silently breaking the other's (portal vs support).

locals {
  cors_response_headers = {
    "gatewayresponse.header.Access-Control-Allow-Origin"  = "'*'"
    "gatewayresponse.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
  }
}

resource "aws_api_gateway_method" "proxy_options" {
  for_each      = local.backends
  rest_api_id   = aws_api_gateway_rest_api.this[each.key].id
  resource_id   = aws_api_gateway_resource.proxy[each.key].id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "proxy_options" {
  for_each    = local.backends
  rest_api_id = aws_api_gateway_rest_api.this[each.key].id
  resource_id = aws_api_gateway_resource.proxy[each.key].id
  http_method = aws_api_gateway_method.proxy_options[each.key].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "proxy_options" {
  for_each    = local.backends
  rest_api_id = aws_api_gateway_rest_api.this[each.key].id
  resource_id = aws_api_gateway_resource.proxy[each.key].id
  http_method = aws_api_gateway_method.proxy_options[each.key].http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
  }
}

resource "aws_api_gateway_integration_response" "proxy_options" {
  for_each    = local.backends
  rest_api_id = aws_api_gateway_rest_api.this[each.key].id
  resource_id = aws_api_gateway_resource.proxy[each.key].id
  http_method = aws_api_gateway_method.proxy_options[each.key].http_method
  status_code = aws_api_gateway_method_response.proxy_options[each.key].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS'"
  }

  depends_on = [aws_api_gateway_integration.proxy_options]
}

# Gateway Responses are account/API-level config, not part of a deployment
# snapshot — they take effect immediately, no redeploy needed.
resource "aws_api_gateway_gateway_response" "unauthorized" {
  for_each      = local.backends
  rest_api_id   = aws_api_gateway_rest_api.this[each.key].id
  response_type = "UNAUTHORIZED"

  response_parameters = local.cors_response_headers
}

resource "aws_api_gateway_gateway_response" "access_denied" {
  for_each      = local.backends
  rest_api_id   = aws_api_gateway_rest_api.this[each.key].id
  response_type = "ACCESS_DENIED"

  response_parameters = local.cors_response_headers
}
