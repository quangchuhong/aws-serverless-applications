terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Tag Ephemeral=true để dễ tìm và dọn nếu destroy sót
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Ephemeral = "true"
    }
  }
}

data "aws_caller_identity" "current" {}
