terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Xem landing-zone/tf-backend. Bo comment sau khi da chay
  # ./wire-backends.sh va them "landing-zone/organization" vao
  # local.layers cua tf-backend.
  # backend "s3" {}
}

########################################
# BAN DIY - Organizations thuan + Terraform.
#
# Day la ban DUNG THAT cho lab. Ban Control Tower nam o
# ../control-tower/ de doi chieu, mac dinh TAT.
#
# Chay o MANAGEMENT ACCOUNT.
########################################

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

locals {
  common_tags = {
    CostCenter  = var.cost_center
    Owner       = var.owner
    Environment = "shared"
    Project     = var.project
    ManagedBy   = "terraform"
    Repo        = "aws-serverless-applications/landing-zone/organization"
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
