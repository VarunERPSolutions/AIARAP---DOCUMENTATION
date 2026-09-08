terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 5.30 for aws_lambda_invocation's lifecycle_scope = "CRUD" (used by
      # the tenant-onboarding module's inventory writes).
      version = ">= 5.30, < 6.0.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}
