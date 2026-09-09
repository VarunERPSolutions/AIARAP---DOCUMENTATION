variable "function_name" {
  description = "Name of the Lambda authorizer function."
  type        = string
  default     = "varunerp-api-authorizer"
}

variable "pool_map" {
  description = "The authorizer's full trust allowlist (ADR-0040): every Cognito pool ID it will accept a token from, keyed by pool ID, each with the (group, env) that pool represents (e.g. {\"us-east-1_xxx\" = {group = \"support\", env = \"dev\"}}). A token's unverified `iss` is matched against these keys to pick which pool's JWKS to verify against — an iss that doesn't match any key here is denied before any cryptographic check is attempted. Populate from the actual pools this stack creates (cognito.tf), never hand-typed."
  type = map(object({
    group = string
    env   = string
  }))
}

variable "api_backend_map" {
  description = "Map of REST API ID -> backend name (\"node\"/\"java\"/\"sap\"). Base-path mappings strip the base path before a request reaches an API, so the API ID is the reliable signal for which backend is being called. Environment comes directly from the request's stage (requestContext.stage) — one REST API per backend, dev/qa/prd are stages of it, not separate APIs. Populate once the per-backend REST APIs exist."
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the authorizer's own log group."
  type        = number
  default     = 30
}

variable "timeout" {
  description = "Lambda timeout in seconds. Kept short — this only verifies a JWT and returns a policy."
  type        = number
  default     = 5
}

variable "memory_size" {
  type    = number
  default = 128
}

variable "reserved_concurrent_executions" {
  description = "Reserves (and caps) concurrency for this function out of the account's shared pool. This gates every request across every backend/environment, so a runaway retry storm from dev/test traffic shouldn't be able to starve prod of Lambda concurrency — that isolation belongs here, not in running a second function. -1 disables reservation (shares the account's unreserved pool with everything else)."
  type        = number
  default     = -1
}
