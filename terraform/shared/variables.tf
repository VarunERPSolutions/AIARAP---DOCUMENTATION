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
  description = "Subnets the app instances live in — java-app's (us-east-1b) and node-app/react-app's shared one (us-east-1a). The internal NLB and the VPC Link both need to span these two."
  type        = list(string)
  default     = ["subnet-04995cb5d11ee98b1", "subnet-06f5722306035b874"]
}
