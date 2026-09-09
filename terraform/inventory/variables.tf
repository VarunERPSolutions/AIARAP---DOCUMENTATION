# vpc_id/private_subnet_ids duplicated from terraform/shared/variables.tf
# (same real account values) rather than shared across states — this is a
# separate root module now, so it needs its own copies rather than a
# cross-state reference. Keep these two in sync with shared's if the
# account's networking ever actually changes.

variable "vpc_id" {
  description = "The single default VPC all three app instances live in."
  type        = string
  default     = "vpc-072f816875fedf904"
}

variable "private_subnet_ids" {
  description = "Subnet IDs for the pg-inventory-writer Lambda's ENIs. Must have network reachability to the aiarap RDS instance. Confirmed via `aws ec2 describe-subnets` (2026-09-09) that vpc-072f816875fedf904 is the default VPC and every one of its subnets has MapPublicIpOnLaunch=true — there are no genuinely private subnets to point at. Defaulting to the same two subnets terraform/shared's NLB uses, accepting that \"private\" here means \"not given its own internet-facing listener,\" not network-isolated."
  type        = list(string)
  default     = ["subnet-04995cb5d11ee98b1", "subnet-06f5722306035b874"]
}

variable "aiarap_db_instance_identifier" {
  description = "RDS instance identifier for the aiarap Postgres database."
  type        = string
}

variable "aiarap_db_name" {
  description = "Database name on that instance to write the inventory schema into."
  type        = string
}

variable "aiarap_db_secret_arn" {
  description = "Secrets Manager secret with {\"username\":..., \"password\":...} for a Postgres role that can create/use the inventory schema."
  type        = string
}

variable "aiarap_db_security_group_id" {
  description = "Security group attached to the aiarap RDS instance. If set, this stack adds an ingress rule allowing 5432 from the pg-inventory-writer Lambda automatically. Leave null to wire that ingress rule yourself."
  type        = string
  default     = null
}
