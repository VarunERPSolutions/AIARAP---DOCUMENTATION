# These reference the shared, created-once stack (Cognito pool + resource
# servers, the shared REST API + Lambda authorizer + VPC Link, the inventory
# table). In practice, pull these from that stack's remote state instead of
# hardcoding — left as variables here so this config can be tested standalone.

variable "route53_zone_id" {
  description = "Hosted zone ID for aiarap.com."
  type        = string
}

variable "cognito_user_pool_id" {
  description = "Shared VarunERP Cognito user pool ID."
  type        = string
}

variable "api_ids" {
  description = "Map of backend name -> REST API ID, one API per backend (Lambda authorizer + VPC Link already wired on each). Base-path mappings strip the base path before a request reaches the target API, so \"/node\" and \"/java\" each need their own underlying API — see modules/lambda-authorizer/README.md."
  type        = map(string)
}

variable "inventory_writer_function_name" {
  description = "Name of the shared pg-inventory-writer Lambda."
  type        = string
  default     = "varunerp-pg-inventory-writer"
}

variable "customers" {
  description = "Customer onboarding list. Add a row here to onboard a new customer; remove one to fully offboard (destroys their certs, domains, Cognito clients, API keys, and secrets)."
  type = map(object({
    environments = optional(list(string), ["dev", "qa", "prd"])
    connections = optional(list(object({
      key     = string
      backend = string
      })), [
      { key = "sf-node", backend = "node" },
      { key = "sap-node", backend = "node" },
      { key = "sap-java", backend = "java" },
    ])
    throttle_overrides = optional(map(object({
      rate_limit  = number
      burst_limit = number
      quota_limit = number
    })), {})
  }))
}
