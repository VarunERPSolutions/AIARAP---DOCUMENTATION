variable "subdomain" {
  description = "The Tenant's subdomain — same value as global.tenant_registry.subdomain in the app's own schema (docs/schema/0001-phase-1-table-structures.md). Used in domain names, resource names, and Cognito client naming (e.g. \"acme\"). Must be a valid DNS label."
  type        = string
}

variable "base_domain" {
  description = "Tenant-facing base domain."
  type        = string
  default     = "aiarap.com"
}

variable "route53_zone_id" {
  description = "Hosted zone ID for base_domain."
  type        = string
}

variable "environments" {
  description = "Environments to provision for this Tenant. \"prd\" is treated as the bare subdomain ({subdomain}.aiarap.com); every other entry gets a prefix (env.{subdomain}.aiarap.com)."
  type        = list(string)
  default     = ["dev", "qa", "prd"]
}

variable "connections" {
  description = "Which source->backend integrations this Tenant needs. `key` becomes part of the client/resource names, `backend` selects the resource server (must be a key in resource_server_identifiers)."
  type = list(object({
    key     = string
    backend = string
  }))
  default = [
    { key = "sf-node", backend = "node" },
    { key = "sap-node", backend = "node" },
  ]
}

variable "resource_server_identifiers" {
  description = "Map of backend name -> Cognito resource server identifier URI. The resource servers and their scopes (\"<backend>.invoke.<env>\") are created once, outside this module."
  type        = map(string)
  default = {
    node = "https://api.aiarap.com/node"
  }
}

variable "cognito_user_pool_ids" {
  description = "Map of environment -> \"syscomms\" Cognito pool ID (ADR-0040) — each Tenant connection's app client is created in the pool matching its own environment, not one shared pool. Created once, outside this module (terraform/shared/cognito.tf)."
  type        = map(string)
}

variable "cognito_domains" {
  description = "Map of environment -> the matching syscomms pool's Hosted UI domain (full host, e.g. \"varunerp-syscomms-dev.auth.us-east-1.amazoncognito.com\"), used for the OAuth token endpoint embedded into each connection's secret. Created once, outside this module — see terraform/shared/cognito.tf's cognito_pool_domains output."
  type        = map(string)
}

variable "api_ids" {
  description = "Map of backend name -> REST API ID, one API per backend (e.g. { node = \"...\" }) — dev/qa/prd are STAGES of that one API, not separate APIs. Base-path mappings strip the base path before a request reaches the target API, so each backend needs its own, wired to the shared Lambda authorizer. Created once, outside this module. Must have an entry for every backend referenced in var.connections."
  type        = map(string)
}

variable "default_throttle" {
  description = "Default per-connection throttle/quota, applied unless overridden in throttle_overrides."
  type = object({
    rate_limit  = number
    burst_limit = number
    quota_limit = number
  })
  default = {
    rate_limit  = 10
    burst_limit = 20
    quota_limit = 50000
  }
}

variable "throttle_overrides" {
  description = "Per-connection throttle overrides, keyed by \"<connection.key>-<environment>\" (e.g. \"sap-node-prd\")."
  type = map(object({
    rate_limit  = number
    burst_limit = number
    quota_limit = number
  }))
  default = {}
}

variable "access_token_validity_hours" {
  description = "Cognito access token lifetime for this Tenant's app clients."
  type        = number
  default     = 1
}

variable "enable_inventory" {
  description = "Whether to write connection records into the shared inventory table."
  type        = bool
  default     = true
}

variable "inventory_writer_function_name" {
  description = "Name of the shared pg-inventory-writer Lambda (created once, outside this module) that upserts/deletes rows in the aiarap RDS global schema on Terraform's behalf."
  type        = string
  default     = "varunerp-pg-inventory-writer"
}
