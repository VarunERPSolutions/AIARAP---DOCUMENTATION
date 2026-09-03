terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 5.30 for aws_lambda_invocation's lifecycle_scope = "CRUD", used in inventory.tf.
      version = ">= 5.30, < 6.0.0"
    }
  }
}
