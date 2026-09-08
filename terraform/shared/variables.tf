# Inputs for the dev CI/CD pipeline (ci.tf) only. Each is the EC2 instance
# that app's dev container(s) run on — used solely to scope the GitHub
# Actions IAM role's ssm:SendCommand permission to exactly those 3 boxes.

variable "node_app_instance_id" {
  description = "EC2 instance running node-app's dev container."
  type        = string
  default     = "i-0e8bb91b84754d419" # per INFRASTRUCTURE_REFERENCE.md
}

variable "java_app_instance_id" {
  description = "EC2 instance running java-app's dev container."
  type        = string
  default     = "i-01afdc2668e71f05b" # per INFRASTRUCTURE_REFERENCE.md
}

# react_app_instance_id (i-0404b22a0807d70b3) removed: react-external-app/
# react-support-app moved to S3+CloudFront (public_apps.tf) and the shared
# react-app EC2 instance is being decommissioned — see docs/adr/0021-parking-lot.md #57.

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
  description = "Subnets the app instances live in — java-app's (us-east-1b) and node-app's (us-east-1a). The internal NLB and the VPC Link both need to span these two."
  type        = list(string)
  default     = ["subnet-04995cb5d11ee98b1", "subnet-06f5722306035b874"]
}

# ---------------------------------------------------------------------------
# Below: inputs for the Tenant integration hub stack (apis.tf, authorizer.tf,
# cognito.tf, domains_sap.tf, flow2.tf, inventory.tf, java_outbound.tf,
# networking.tf) — restored from the merge-varunerp-network-infra branch.
# Per docs/infra/README.md, this stack is designed but NOT YET APPLIED
# against real AWS; several variables below are deliberately left with no
# default (required) until their real values are confirmed — do not invent
# values for these, fill them in when this stack is actually ready to apply.
# ---------------------------------------------------------------------------

variable "private_subnet_ids" {
  description = "Private subnet IDs for the internal NLB (networking.tf) and the pg-inventory-writer Lambda's ENIs. Must have network reachability to node-app, java-app, the SAP tailnet-proxy, and aiarap RDS. Likely the same subnets as app_server_subnet_ids above, but left as its own required variable rather than assumed, since this stack's NLB is separate from gateway_network.tf's."
  type        = list(string)
}

# --- Node backend (Tenant integration hub) ---
#
# One entry per environment. dev and qa currently share one EC2 instance
# (see docker/README.md) — different containers, different host ports. prd
# will be its own dedicated instance (confirmed) but ISN'T PROVISIONED YET —
# its entry below is a placeholder (an obviously-fake instance_id) purely to
# keep the intended shape visible. Replace "i-PLACEHOLDER-*" with the real
# instance ID once that box exists.
#
# No java_environments here — Java has no inbound Tenant-facing routing at
# all (ADR-0039). See java_outbound.tf for its actual infrastructure.

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

variable "java_app_iam_role_name" {
  description = "IAM role name attached to java_app_instance_id, if you want java_outbound.tf's policy attached automatically. Leave null to just get the policy ARN as an output and attach it yourself."
  type        = string
  default     = null
}

variable "tenant_sap_secret_arn_pattern" {
  description = "Resource pattern (with wildcards) matching every Tenant's SAP credential secrets — tenant_settings.sap_credential_secret_ref / sap_oauth_token_secret_ref in the app's own schema (docs/schema/0001-phase-1-table-structures.md). Default is a reasonable guess at the naming convention, NOT confirmed against whatever the app's secret-creation code actually uses — verify before relying on it."
  type        = string
  default     = "arn:aws:secretsmanager:*:*:secret:aiarap/tenant/*/sap-*"
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

variable "aiarap_com_zone_id" {
  description = "Route53 hosted zone ID for aiarap.com — same zone modules/tenant-onboarding uses for per-Tenant domains. NOT currently used by public_apps.tf/public_apps_domain.tf (those use manual Hostinger DNS instead — no Route53 zone was found for aiarap.com when that work was done; reconcile if/when this stack is actually adopted)."
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
