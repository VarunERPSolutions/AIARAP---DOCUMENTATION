terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 5.30 floor kept from before the pg-inventory-writer extraction
      # (2026-09-09, moved to terraform/inventory/) — nothing left in this
      # stack specifically needs it, but no reason to loosen an already-
      # satisfied constraint either.
      version = ">= 5.30, < 6.0.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}
