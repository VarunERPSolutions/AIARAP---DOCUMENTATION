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
