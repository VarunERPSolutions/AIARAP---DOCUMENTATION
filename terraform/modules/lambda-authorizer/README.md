# lambda-authorizer

A REST API **REQUEST**-type Lambda authorizer, shared across both inbound
REST APIs in the shared stack (`node`, `sap`). Java has no inbound API —
see `terraform/shared/java_outbound.tf` — so it's not wired to this
authorizer at all. Per request, it:

1. Extracts the bearer token from `Authorization`, verifies it against the
   Cognito user pool's JWKS (signature, expiry, `token_use: access`) using
   `aws-jwt-verify`.
2. Resolves **backend** from `event.requestContext.apiId` via
   `API_BACKEND_MAP` — not from the path, since API Gateway base-path
   mappings strip the base path before a request reaches the underlying API
   (`{subdomain}.aiarap.com/node/orders`, once matched by the `node` base path
   mapping, arrives at the target API as `/orders`) — apiId is the only
   signal left that survives that.
3. Resolves **environment** directly from `event.requestContext.stage`.
   There's no Host-header parsing and no per-apiId environment config:
   since each backend is one REST API with one stage per environment (dev,
   qa, prd — see `terraform/shared`), the stage API Gateway already
   resolved *is* the environment, by construction.
4. Requires the token's `scope` claim to contain `<backend>.invoke.<stage>`;
   allows or denies accordingly.
5. Returns an IAM policy wildcarded to `stage/*/*` of the invoking API, not
   just the one method that was called — the decision only ever depends on
   (scope, apiId, stage), never on which specific operation was hit, so this
   is what keeps a later caching config from denying `/orders` because a
   cached policy was pinned to `/invoices`.

## Inputs this module needs from the shared stack

- `cognito_user_pool_id` — the shared user pool
- `api_backend_map` — one entry per REST API, e.g.:
  ```hcl
  {
    "<node-api-id>" = "node"
    "<sap-api-id>"  = "sap"
  }
  ```

## Wiring it into each REST API (done in `terraform/shared`, not here)

```hcl
resource "aws_api_gateway_authorizer" "shared" {
  name                              = "varunerp-authorizer"
  rest_api_id                       = aws_api_gateway_rest_api.this["node"].id  # once per API
  type                              = "REQUEST"
  authorizer_uri                    = module.authorizer.invoke_arn
  identity_source                   = "method.request.header.Authorization"
  authorizer_result_ttl_in_seconds  = 0  # see note below
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke-node"
  action        = "lambda:InvokeFunction"
  function_name = module.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this["node"].execution_arn}/authorizers/${aws_api_gateway_authorizer.shared.id}"
}
```

Repeat both resources for `sap`, pointing at the same
`module.authorizer.invoke_arn`. Note `identity_source` no longer needs
`Host` — environment comes from the stage, which API Gateway resolves
before the authorizer even runs, so it can't be part of what gates caching
correctness the way it used to.

**On caching**: since the decision only depends on (scope, apiId, stage),
and stage/apiId are inherent to which deployed endpoint was hit — not
something a request can spoof via headers — caching would be safe here in
principle. Starting with `authorizer_result_ttl_in_seconds = 0` (no
caching) is still the simplest correct default for this traffic profile
(B2B integration calls, not high-QPS web traffic); revisit only if
authorizer invocation cost/latency actually becomes a problem.
