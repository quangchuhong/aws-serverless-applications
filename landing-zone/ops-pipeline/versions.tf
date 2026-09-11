########################################
# PIPELINE VAN HANH
#
# Chay o ACCOUNT MANAGEMENT. Xem main.tf muc "Vi sao khong gop vao
# vending-pipeline".
#
# ---------------------------------------------------------------
# BACKEND CUA CHINH LAYER NAY
#
# Nhu moi layer khac: khoa khai o landing-zone/tf-backend/outputs.tf,
# file backend.tf do wire-backends.sh sinh. KHONG go tay vao day.
########################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60, < 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      ManagedBy   = "terraform"
      Layer       = "ops-pipeline"
      Environment = "prod"
      CostCenter  = var.cost_center
      Owner       = var.owner
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
