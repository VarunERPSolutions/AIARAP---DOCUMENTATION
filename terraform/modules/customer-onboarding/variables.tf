variable "customer_id" {
  description = "Short customer identifier used in domain names, resource names, and Cognito client naming (e.g. \"cust01\"). Must be a valid DNS label."
  type        = string
}

variable "base_domain" {
  description = "Customer-facing base domain."
  type        = string
  default     = "aiarap.com"
}

variable "route53_zone_id" {
  description = "Hosted zone ID for base_domain."
  type        = string
}

variable "environments" {
  description = "Environments to provision for this customer. \"prd\" is treated as the bare subdomain (custXX.aiarap.com); every other entry gets a prefix (env.custXX.aiarap.com)."
  type        = list(string)
  default     = ["dev", "qa", "prd"]
}

variable "connections" {
  description = "Which source->backend integrations this customer needs. `key` becomes part of the client/resource names, `backend` selects the resource server (must be a key in resource_server_identifiers)."
  type = list(object({
    key     = string
    backend = string
  }))
  default = [
    { key = "sf-node", backend = "node" },
    { key = "sap-node", backend = "node" },
    { key = "sap-java", backend = "java" },
  ]
}

variable "resource_server_identifiers" {
  description = "Map of backend name -> Cognito resource server identifier URI. The resource servers and their scopes (\"<backend>.invoke.<env>\") are created once, outside this module."
  type        = map(string)
  default = {
    node = "https://api.aiarap.com/node"
    java = "https://api.aiarap.com/java"
  }
}

variable "cognito_user_pool_id" {
  description = "ID of the shared VarunERP Cognito user pool (created once, outside this module)."
  type        = string
}

variable "cognito_domain" {
  description = "Cognito hosted domain used for the OAuth token endpoint, embedded into each connection's secret for the customer's convenience."
  type        = string
  default     = "auth.varunerpsolutions.com"
}

variable "api_ids" {
  description = "Map of backend name -> REST API ID, one API per backend (e.g. { node = \"...\", java = \"...\" }) — dev/qa/prd are STAGES of that one API, not separate APIs. Base-path mappings strip the base path before a request reaches the target API, so \"/node\" and \"/java\" cannot share one underlying API — each backend needs its own, wired to the shared Lambda authorizer. Created once, outside this module. Must have an entry for every backend referenced in var.connections."
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
  description = "Per-connection throttle overrides, keyed by \"<connection.key>-<environment>\" (e.g. \"sap-java-prd\")."
  type = map(object({
    rate_limit  = number
    burst_limit = number
    quota_limit = number
  }))
  default = {}
}

variable "access_token_validity_hours" {
  description = "Cognito access token lifetime for this customer's app clients."
  type        = number
  default     = 1
}

variable "enable_inventory" {
  description = "Whether to write connection records into the shared inventory table."
  type        = bool
  default     = true
}

variable "inventory_writer_function_name" {
  description = "Name of the shared pg-inventory-writer Lambda (created once, outside this module) that upserts/deletes rows in the aiarap RDS inventory schema on Terraform's behalf."
  type        = string
  default     = "varunerp-pg-inventory-writer"
}
