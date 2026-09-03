# --- Networking ---

variable "vpc_id" {
  description = "VarunERP's VPC."
  type        = string
  default     = "vpc-072f816875fedf904" # per INFRASTRUCTURE_REFERENCE.md
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the internal NLB and the pg-inventory-writer Lambda's ENIs. Must have network reachability to node-app, java-app, the SAP tailnet-proxy, and aiarap RDS."
  type        = list(string)
}

# --- Node / Java backends ---
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

variable "java_environments" {
  description = "Map of environment -> { instance_id, port } for java-app. `port` is used as both the NLB listener port and the target port on that instance."
  type = map(object({
    instance_id = string
    port        = number
  }))
  default = {
    dev = { instance_id = "i-01afdc2668e71f05b", port = 4001 }    # shares the instance with qa
    qa  = { instance_id = "i-01afdc2668e71f05b", port = 4002 }    # shares the instance with dev
    prd = { instance_id = "i-PLACEHOLDER-java-prd", port = 8080 } # NOT YET PROVISIONED — do not apply as-is
  }
}

# --- SAP backend ---

variable "sap_proxy_instance_id" {
  description = "EC2 instance that bridges VPC-private traffic into the Tailscale overlay to reach SAP (nginx/socat forwarding each environment's port below to the matching SAP HANA instance's Tailscale address — that forwarding config is outside this Terraform). Either aws-subnet-router repurposed, or a new dedicated box — your call, not assumed here."
  type        = string
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
