terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  ########################################
  # Remote state
  #
  # Khai rong o day, gia tri that nam trong backend.hcl - file do
  # landing-zone/tf-backend/wire-backends.sh sinh ra.
  #
  #   cd landing-zone/tf-backend && ./wire-backends.sh
  #   cd landing-zone/billing-guard
  #   terraform init -migrate-state -backend-config=backend.hcl
  #
  # Chua dung remote state thi cu de comment - state se nam local,
  # chap nhan duoc khi chi mot nguoi lam.
  ########################################

  # backend "s3" {}
}

########################################
# TAT CA o us-east-1.
#
# Cost Explorer API, Budgets va metric AWS/Billing deu chi ton tai
# o us-east-1, du chi phi la cua toan bo cac region.
# Dat provider o region khac se loi hoac khong thay du lieu.
########################################

########################################
# Layer nay cung phai mang chinh nhung tag no bat cost allocation.
# Khong thi resource cua no lot khoi bao cao - nghe nho nhung la
# loi logic kho chiu khi doc bao cao sau nay.
#
# KHONG co Ephemeral=true: layer nay dung mot lan roi de do,
# khong nam trong pham vi teardown cua demo.
########################################

locals {
  common_tags = {
    CostCenter  = var.cost_center
    Owner       = var.owner
    Environment = "prod" # ha tang quan tri, khong phai sandbox
    Project     = var.project

    ManagedBy = "terraform"
    Layer     = "billing-guard"
    Repo      = "aws-serverless-applications/landing-zone/billing-guard"
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_organizations_organization" "current" {}
