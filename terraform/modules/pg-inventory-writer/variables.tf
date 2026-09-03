variable "function_name" {
  description = "Name of the writer Lambda."
  type        = string
  default     = "varunerp-pg-inventory-writer"
}

variable "db_host" {
  description = "aiarap RDS Postgres endpoint (host only, no port)."
  type        = string
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_name" {
  description = "Database name on the aiarap RDS instance to write the inventory into."
  type        = string
}

variable "db_schema" {
  description = "Schema holding the integration_connection table — defaults to the app's own `global` schema (ADR-0004), since this is AIARAP-internal cross-Tenant governance data, not Tenant business data needing schema-per-tenant isolation. Only override if you deliberately want a separate schema instead."
  type        = string
  default     = "global"
}

variable "db_secret_arn" {
  description = "Secrets Manager secret containing {\"username\":..., \"password\":...} for a Postgres role with CREATE/usage rights on db_schema. Host/port/db name are passed separately, not read from this secret."
  type        = string
}

variable "vpc_subnet_ids" {
  description = "Private subnet IDs the Lambda's ENIs attach to — must have network reachability to aiarap RDS (same VPC, routable security groups)."
  type        = list(string)
}

variable "vpc_security_group_ids" {
  description = "Security groups for the Lambda's ENIs. The aiarap RDS security group must allow inbound 5432 from (at least) one of these."
  type        = list(string)
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "timeout" {
  description = "Lambda timeout in seconds. VPC-attached + a DB round trip, so a bit more headroom than the authorizer."
  type        = number
  default     = 10
}

variable "memory_size" {
  type    = number
  default = 128
}
