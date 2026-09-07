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
# at all (ADR-0017). See java_outbound.tf for its actual infrastructure.

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
  description = "EC2 instance running the Java/Spring Batch nightly SAP extraction service (ADR-0017). Purely for reference/tagging in this stack — this Terraform doesn't manage its IAM instance role (never has), so java_outbound.tf's IAM policy is created standalone with its ARN as an output; attach it to that instance's role yourself, or pass its role name in if you want this stack to attach it directly."
  type        = string
  default     = "i-01afdc2668e71f05b" # per INFRASTRUCTURE_REFERENCE.md
}

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

# --- React frontends (CI deploy target only — not otherwise routed by this stack) ---

variable "react_app_instance_id" {
  description = "EC2 instance running both React apps' dev containers (external-app, support-app share this box — see docker/README.md). Used only to scope the GitHub Actions CI role's ssm:SendCommand permission (ci.tf); this stack doesn't otherwise manage react-app's infrastructure."
  type        = string
  default     = "i-0404b22a0807d70b3" # per INFRASTRUCTURE_REFERENCE.md
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
  description = "Route53 hosted zone ID for aiarap.com — same zone modules/tenant-onboarding uses for per-Tenant domains. Hosts the two public portal apps' domains (public_apps.tf, ADR-0033)."
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
