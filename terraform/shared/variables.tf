# Inputs for the dev CI/CD pipeline (ci.tf) only. Each is the EC2 instance
# that app's dev container(s) run on — used solely to scope the GitHub
# Actions IAM role's ssm:SendCommand permission to exactly those 3 boxes.

variable "node_app_instance_id" {
  description = "EC2 instance running node-app's dev container."
  type        = string
  default     = "i-0e8bb91b84754d419" # per INFRASTRUCTURE_REFERENCE.md
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the internal NLB and the pg-inventory-writer Lambda's ENIs. Must have network reachability to node-app, java-app, the SAP tailnet-proxy, and aiarap RDS."
  type        = list(string)
}

# --- Node backend ---
#
# One entry per environment. dev and qa currently share one EC2 instance
# (see docker/README.md) — different containers, different host ports. prd
# will be its own dedicated instance (confirmed) but ISN'T PROVISIONED YET —
# its entry below is a placeholder (an obviously-fake instance_id) purely to
# keep the intended shape visible. Replace "i-PLACEHOLDER-*" with the real
# instance ID once that box exists; nothing else needs to change to pick it
# up (NLB listener/target group, stage, and Cognito scope all already exist
# or fan out automatically). Do not point prd at the same instance_id as
# dev/qa — the check block below catches that mistake at plan time, and a
# real instance ID (unlike this placeholder) is what makes it safe to apply.
#
# No java_environments here — Java has no inbound Tenant-facing routing
# at all (ADR-0039). See java_outbound.tf for its actual infrastructure.

variable "node_environments" {
  description = "Map of environment -> { instance_id, port } for node-app. `port` is used as both the NLB listener port and the target port on that instance."
  type = map(object({
    instance_id = string
    port        = number
  }))
  default = {
    dev = { instance_id = "i-0e8bb91b84754d419", port = 3001 }    # shares the instance with qa
    qa  = { instance_id = "i-0e8bb91b84754d419", port = 3002 }    # shares the instance with dev
    prd = { instance_id = "i-PLACEHOLDER-node-prd", port = 3000 } # NOT YET PROVISIONED — do not apply as-is
  }
}

# --- Java backend (outbound only — see java_outbound.tf) ---

variable "java_app_instance_id" {
  description = "EC2 instance running the Java/Spring Batch nightly SAP extraction service (ADR-0039). Purely for reference/tagging in this stack — this Terraform doesn't manage its IAM instance role (never has). Not part of gateway_network.tf's VPC Link — Java has no Tenant-facing inbound routing (ADR-0039)."
  type        = string
  default     = "i-01afdc2668e71f05b" # per INFRASTRUCTURE_REFERENCE.md
}

variable "react_app_instance_id" {
  description = "EC2 instance running both React apps' dev containers (external-app, support-app share this box — see docker/README.md)."
  type        = string
  default     = "i-0404b22a0807d70b3" # per INFRASTRUCTURE_REFERENCE.md
}

# Inputs for gateway_network.tf (internal NLB + VPC Link, ADR-0003's gateway
# reaching the backends). All three app instances confirmed live in this one
# default VPC via `aws ec2 describe-instances`, 2026-09-07 — see
# INFRASTRUCTURE_REFERENCE.md §2.

variable "vpc_id" {
  description = "The single default VPC all three app instances live in."
  type        = string
  default     = "vpc-072f816875fedf904"
}

variable "app_server_subnet_ids" {
  description = "Subnets the internal NLB and API Gateway VPC Link span (node-app/react-app's AZ, us-east-1a, plus java-app's AZ, us-east-1b, for multi-AZ coverage — java-app itself isn't a VPC Link target, per ADR-0039)."
  type        = list(string)
  default     = ["subnet-04995cb5d11ee98b1", "subnet-06f5722306035b874"]
}

variable "sap_environments" {
  description = "SAP environments actually provisioned so far. SAP dev and prod are physically distinct HANA systems (unlike node/java's shared-instance dev/qa), so each needs its own NLB listener/target + public domain even though they share one REST API via stages. Add \"prd\" here once SAP prod is stood up (and once the tailnet-proxy has a stream block forwarding its port to sap.varunerpsolutions.com)."
  type = map(object({
    port = number
  }))
  default = {
    dev = { port = 8083 }
  }
}

# --- DNS ---

variable "varunerpsolutions_com_zone_id" {
  description = "Route53 hosted zone ID for varunerpsolutions.com (hosts the Cognito auth domain and the public SAP API domains)."
  type        = string
}

variable "aiarap_com_zone_id" {
  description = "Route53 hosted zone ID for aiarap.com — same zone modules/tenant-onboarding uses for per-Tenant domains. Hosts the two public portal apps' domains (public_apps.tf, ADR-0038)."
  type        = string
}

# --- Cognito / API Gateway ---

variable "authorizer_reserved_concurrency" {
  description = "Reserved concurrency for the shared authorizer Lambda (see modules/lambda-authorizer). -1 to leave it unreserved."
  type        = number
  default     = 50
}

# --- aiarap RDS (for pg-inventory-writer) ---

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
