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
# TAT CA o us-east-1.
#
# Cost Explorer API, Budgets va metric AWS/Billing deu chi ton tai
# o us-east-1, du chi phi la cua toan bo cac region.
# Dat provider o region khac se loi hoac khong thay du lieu.
########################################

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Layer     = "billing-guard"
      # KHONG co Ephemeral=true: layer nay dung mot lan roi de do,
      # khong nam trong pham vi teardown cua demo.
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_organizations_organization" "current" {}
