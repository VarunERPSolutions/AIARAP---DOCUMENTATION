# lambda-authorizer

> **Status:** implements the 9-pool design from [ADR-0040](../../../docs/adr/0040-nine-cognito-pool-architecture.md). Drafted in this branch, **not yet applied** to real AWS.

A REST API **REQUEST**-type Lambda authorizer, shared across both inbound
REST APIs in the shared stack (`node`, `sap`). Java has no inbound API —
see `terraform/shared/java_outbound.tf` — so it's not wired to this
authorizer at all. Per request, it:

1. Extracts the bearer token from `Authorization`.
2. Decodes the token's `iss` claim **without verifying it yet**, and
   matches it against `POOL_MAP` — a fixed allowlist of every Cognito pool
   ID this authorizer trusts, each tagged with the (group, env) it
   represents. Terraform (`cognito.tf`) populates this from the 9 pools it
   actually creates; the Lambda never invents or extends this list. An
   `iss` that doesn't match any entry is denied immediately — no JWKS
   fetch, no signature check, nothing cryptographic happens for an
   unrecognized issuer.
3. **Verifies** the token — the step that actually trusts it — against the
   matched pool's own JWKS (signature, expiry, `token_use: access`) via
   `aws-jwt-verify`, using a `CognitoJwtVerifier` built for that specific
   pool ID. `aws-jwt-verify` independently re-derives the expected issuer
   from that pool ID + region and checks the token's `iss` against *that*,
   so step 2's lookup being tricked somehow still can't produce a false
   Allow — the unverified `iss` only ever selected which pre-configured
   verifier ran, it was never itself the trust decision.
4. Resolves **backend** from `event.requestContext.apiId` via
   `API_BACKEND_MAP` — unchanged from before: base-path mappings strip the
   base path before a request reaches the underlying API, so apiId is the
   reliable signal for which backend is being called.
5. Resolves **environment** from `event.requestContext.stage`, and checks
   it against the matched pool's own `env` — a `syscomms-dev`-issued token
   cannot authenticate against the `prd` stage, even before any scope
   check, because the pool itself (not a scope suffix) is what encodes
   environment now.
6. Checks the matched pool's **group** (`support`/`portal`/`syscomms`) is
   even permitted to call this backend — support/portal groups are
   node-only; syscomms may call node or sap — and that the token's `scope`
   claim contains that group's required scope (`node.support`,
   `node.portal`, `node.invoke`, or `sap.invoke` — no environment suffix,
   dropped in ADR-0040 since the pool already encodes it).
7. Allows or denies accordingly, and passes which group/scope matched
   through as `context.group`/`context.scope` — same caveat as before: API
   Gateway's `HTTP_PROXY` integration has no request-parameter mapping
   forwarding `context.*` into the backend request, so nothing from this
   function's decision survives into NestJS except the original
   `Authorization` header. Per-route enforcement is still NestJS's job (see
   Deliberate gap below).
8. Returns an IAM policy wildcarded to `stage/*/*` of the invoking API, not
   just the one method that was called — the decision only ever depends on
   (matched pool, apiId, stage), never on which specific operation was hit,
   so this stays safe if authorizer caching is ever turned on later.

## One shared Lambda for all 9 pools, not 9 separate authorizers

Deliberate choice, not a default kept out of inertia:

- **Latency**: `CognitoJwtVerifier.create()` doesn't fetch JWKS eagerly — a
  pool's JWKS is fetched (and cached for the container's lifetime) on that
  pool's *first* `.verify()` call. Building all (up to) 9 verifiers at cold
  start costs one extra object construction each, not 9 JWKS fetches
  upfront — the actual network cost is the same "fetch once per pool per
  warm container" shape the old single-pool version already had, just
  potentially repeated for however many of the 9 pools that container
  actually sees traffic for. Splitting into 9 separate functions would
  instead multiply **cold starts** — 9 independent Lambdas, 9 independent
  warm-container populations, most of which see far less traffic than the
  combined function does today and so stay cold more often.
- **Security**: the trust boundary here is `POOL_MAP` (a fixed, Terraform-
  authored allowlist) and the per-pool JWKS verification itself — both are
  identical whether they live in 1 function or 9. A shared function
  doesn't weaken isolation between pools: a `support-dev` token can't pass
  as a `portal-prd` token no matter how many Lambdas are involved, because
  the verification is still scoped to the one pool `iss` selected. What 9
  separate functions *would* add is 9x the IAM roles, log groups, and
  deploy artifacts to keep in sync for identical code — operational
  overhead with no corresponding security gain, since the code path is
  the same regardless.
- **Operational**: one codebase, one deploy, one set of logs to check.
  Terraform already attaches this single function as multiple
  `aws_api_gateway_authorizer` resources (one per REST API — `node`, `sap`)
  today; extending `POOL_MAP` to 9 entries is the same pattern, not a new
  one.

Revisit this only if a real, measured latency or blast-radius problem
shows up in production — not preemptively.

**Deliberate gap, solved downstream, not here**: this authorizer only ever
answers "is this token valid, for a pool whose group/env matches this
backend+stage, with the right scope" — never "which specific routes can
this group reach." That per-route restriction is enforced by
`AIARAP-node-backend`'s `ScopeGuard` (`src/gateway-client/scope.guard.ts`)
— **not yet built**, confirmed absent from the current `AIARAP-node-backend`
source as of this writing — registered globally, fails closed on any route
missing `@RequireScope`, and re-verifies the token independently rather
than trusting this authorizer's decision (the API Gateway `HTTP_PROXY`
integration has no request-parameter mapping forwarding `context.*` into
the backend request, so nothing from this function's decision survives
into NestJS except the original `Authorization` header). See ADR-0038 and
parking lot #55.

## Inputs this module needs from the shared stack

- `pool_map` — every trusted pool, keyed by pool ID:
  ```hcl
  {
    "<support-dev-pool-id>"  = { group = "support",  env = "dev" }
    "<support-qa-pool-id>"   = { group = "support",  env = "qa"  }
    "<support-prd-pool-id>"  = { group = "support",  env = "prd" }
    "<portal-dev-pool-id>"   = { group = "portal",   env = "dev" }
    # ... 9 entries total — see terraform/shared/cognito.tf's cognito_pool_map local
  }
  ```
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
`module.authorizer.invoke_arn`.

**On caching**: since the decision only depends on (matched pool, apiId,
stage), and apiId/stage are inherent to which deployed endpoint was hit —
not something a request can spoof via headers — caching would be safe here
in principle. Starting with `authorizer_result_ttl_in_seconds = 0` (no
caching) is still the simplest correct default for this traffic profile
(B2B integration calls, not high-QPS web traffic); revisit only if
authorizer invocation cost/latency actually becomes a problem.
