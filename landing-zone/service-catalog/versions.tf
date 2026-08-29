terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Backend nam trong backend.tf, do landing-zone/tf-backend/wire-backends.sh
  # sinh ra va nam trong .gitignore. Khong co file do -> state local.
}

########################################
# CHAY O DAU - doc truoc khi apply
#
# Portfolio nam o MOT account roi chia sang cac account khac. Account
# do la "hub" cua catalog.
#
# Layer nay KHONG assume role sang account khac. No chay o dung account
# ma credential cua ban dang tro toi. Ly do: chia portfolio ra OU can
# quyen Organizations, va gan TagOption can quyen Service Catalog - hai
# thu do de o cung mot cho thi don gian hon nhieu so voi mot alias
# nua phai bao tri.
#
#   Chay o management account:
#     unset AWS_PROFILE && terraform apply
#
#   Chay o account shared-services rieng:
#     AWS_PROFILE=<hub> terraform apply
#
# NEN dung cach thu hai khi to chuc lon len. Management account nen
# SACH: khong workload, rat it nguoi vao, va SCP khong ap len no nen
# moi quyen cap o day la quyen that khong co tran chan - trong khi
# catalog tu phuc vu la thu nguoi ta vao thuong xuyen.
#
# check "catalog_not_in_management" nhac dieu do luc plan.
########################################

provider "aws" {
  region = var.region

  default_tags { tags = local.common_tags }
}

locals {
  enabled = var.enable

  common_tags = {
    CostCenter  = var.cost_center
    Owner       = var.owner
    Environment = "shared"
    Project     = var.project
    ManagedBy   = "terraform"
    Repo        = "aws-serverless-applications/landing-zone/service-catalog"
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
