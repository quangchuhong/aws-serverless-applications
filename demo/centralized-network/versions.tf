terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

########################################
# TAG CHUAN
#
# Bon tag dau la tag bat buoc theo doc 11 muc 2, va la nhung tag
# duoc bat cost allocation o landing-zone/billing-guard.
# Khong gan chung thi Cost Explorer khong group theo tag duoc.
#
# Ephemeral=true chi co o demo, de teardown quet tim resource sot.
########################################

locals {
  common_tags = {
    CostCenter  = var.cost_center
    Owner       = var.owner
    Environment = var.environment
    Project     = var.project

    ManagedBy = "terraform"
    Repo      = "aws-serverless-applications/demo/centralized-network"
    Ephemeral = "true"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}
