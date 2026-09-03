terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 5.30 for aws_lambda_invocation's lifecycle_scope = "CRUD" (delete-on-destroy support).
      version = ">= 5.30, < 6.0.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
