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

# Inputs shared by java_internal_lb.tf (Node's internal LB path to Java,
# ADR-0042) and networking.tf (the external-facing internal NLB feeding
# API Gateway, ADR-0039). All three app instances confirmed live in this
# one default VPC via `aws ec2 describe-instances`, 2026-09-07 — see
# INFRASTRUCTURE_REFERENCE.md §2.
#
# The old gateway_network.tf this comment used to point at is gone — it
# wired java_app behind the external-facing VPC Link, which contradicted
# the already-tracked Java-outbound-only decision; see ADR-0042 §0 for the
# full reconciliation. app_server_subnet_ids itself is unaffected — it's a
# real, still-correct pair of subnets, just now consumed by a different
# (internal-only) load balancer for Java's side.

variable "vpc_id" {
  description = "The single default VPC all three app instances live in."
  type        = string
  default     = "vpc-072f816875fedf904"
}

variable "app_server_subnet_ids" {
  description = "Subnets the app instances live in — java-app's (us-east-1b) and node-app's (us-east-1a). Both the external-facing internal NLB (networking.tf) and Java's own internal-only LB (java_internal_lb.tf, ADR-0042) need to span these two."
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
  description = "Subnet IDs for the internal NLB (networking.tf) and the pg-inventory-writer Lambda's ENIs. Must have network reachability to node-app, java-app, the SAP tailnet-proxy, and aiarap RDS. Confirmed via `aws ec2 describe-subnets` (2026-09-09) that vpc-072f816875fedf904 is the default VPC and every one of its subnets has MapPublicIpOnLaunch=true — there are no genuinely private subnets to point at. Defaulting to the same two subnets app_server_subnet_ids already uses (java_internal_lb.tf's Java-only internal NLB reuses them too), accepting that \"private\" here means \"not given its own internet-facing listener,\" not network-isolated. Replace with real private subnets (+ NAT) if that isolation ever actually matters."
  type        = list(string)
  default     = ["subnet-04995cb5d11ee98b1", "subnet-06f5722306035b874"]
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
# Java has no *Tenant-facing* routing here (ADR-0039 unchanged — see
# java_outbound.tf for its outbound-only infrastructure). It does have its
# own private, internal-only routing for Node's synchronous calls — see
# java_environments below and java_internal_lb.tf (ADR-0042).

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

# --- Java backend: internal-only synchronous path (java_internal_lb.tf, ADR-0042) ---
#
# Same per-environment shape as node_environments, except instance_ids is a
# LIST — production needs >=2 for horizontal capacity/availability; dev/qa
# may run 1 today behind the identical topology. dev/qa share one EC2
# instance (two Docker containers, different host ports, same as
# node_environments/docker/README.md). prd ISN'T PROVISIONED YET — its
# placeholder list deliberately holds 2 entries so the >=2-instance shape
# is visible even before real IDs exist; replace both with real instance
# IDs (ideally in the two different app_server_subnet_ids/AZs) once that
# capacity is provisioned.

variable "java_environments" {
  description = "Map of environment -> { instance_ids, port } for java-app's internal synchronous path. `instance_ids` is a list (>=2 in prod) since a target group attachment is one resource per instance. `port` is used as both the internal NLB listener port and the target port on every instance in the list."
  type = map(object({
    instance_ids = list(string)
    port         = number
  }))
  default = {
    dev = { instance_ids = ["i-01afdc2668e71f05b"], port = 4001 }                                  # shares the instance with qa
    qa  = { instance_ids = ["i-01afdc2668e71f05b"], port = 4002 }                                  # shares the instance with dev
    prd = { instance_ids = ["i-PLACEHOLDER-java-prd-1", "i-PLACEHOLDER-java-prd-2"], port = 8080 } # NOT YET PROVISIONED — do not apply as-is; keep >=2 entries once real IDs are known
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
  description = "EC2 instance that bridges VPC-private traffic into the Tailscale overlay to reach SAP (nginx/socat forwarding each environment's port below to the matching SAP HANA instance's Tailscale address — that forwarding config is outside this Terraform). Either aws-subnet-router repurposed, or a new dedicated box — your call, not assumed here. TEMPORARY placeholder default below (2026-09-09) so plans/applies that don't touch SAP resources (e.g. the Cognito/authorizer dev-flow work) don't need a real value — networking.tf's aws_lb_target_group_attachment.backend has a precondition that hard-fails an apply if this placeholder is still set on any resource that's actually part of that apply. Replace with a real instance ID before applying anything SAP-related."
  type        = string
  default     = "i-PLACEHOLDER-sap-proxy"
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
  description = "Route53 hosted zone ID for varunerpsolutions.com (hosts the public SAP API domains, domains_sap.tf — no longer the Cognito auth domain, which switched to Cognito's built-in *.amazoncognito.com domains under ADR-0040). TEMPORARY placeholder default below (2026-09-09) so plans/applies that don't touch SAP resources don't need a real value — domains_sap.tf's aws_route53_record.sap_api_cert_validation has a precondition that hard-fails an apply if this placeholder is still set on any resource that's actually part of that apply. Replace with the real zone ID before applying anything SAP-domain-related."
  type        = string
  default     = "PLACEHOLDER-ZONE-ID"
}

# aiarap_com_zone_id removed (2026-09-09) — dead variable, zero references
# anywhere in this tree. If a real per-Tenant aiarap.com Route53 zone is
# ever adopted, re-add it then rather than carrying an unused required
# variable indefinitely.

# --- Cognito / API Gateway ---

variable "authorizer_reserved_concurrency" {
  description = "Reserved concurrency for the shared authorizer Lambda (see modules/lambda-authorizer). -1 to leave it unreserved. Was 50 originally, but this account's actual Lambda concurrency ceiling is only 10 total (confirmed via `aws lambda get-account-settings`, 2026-09-09) — AWS requires >=10 unreserved remaining after any reservation, so any positive value here is currently impossible, not just this specific one. Left unreserved until the account's limit is raised (an AWS support request, not a Terraform change)."
  type        = number
  default     = -1
}

# aiarap_db_instance_identifier / aiarap_db_name / aiarap_db_secret_arn /
# aiarap_db_security_group_id removed (2026-09-09) — the pg-inventory-writer
# concern they fed (inventory.tf) moved to its own root module,
# terraform/inventory/, since it had no cross-references into this stack's
# Cognito/API Gateway/authorizer resources. See that module's variables.tf.
