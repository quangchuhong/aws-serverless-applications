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
# ACCOUNT BASELINE
#
# MAC DINH TAT (enable = false).
#
# ---------------------------------------------------------------
# VI SAO CO LAYER NAY
#
# Them mot account vao LZ co BA viec tay, va KHONG viec nao bao loi
# khi quen:
#
#   1. move-account vao dung OU
#      Quen -> account chi con SCP o root. Mat network_lock va
#      prod_guard, ma van chay binh thuong.
#
#   2. Xoa default VPC o moi region
#      Quen -> mot Internet Gateway mo san. network_lock chan TAO
#      IGW moi, nhung khong dung toi cai AWS da tao luc mo account.
#
#   3. Them account ID vao accounts_by_scope (permission-sets)
#      Quen -> khong ai vao duoc account do qua Identity Center,
#      va nguoi ta se quay ra dung root.
#
# Ba sai lech lang le - dung thu ma landing zone sinh ra de ngan.
#
# ---------------------------------------------------------------
# VI SAO KHONG DUNG AFT
#
# Account Factory for Terraform la cua CONTROL TOWER. Ban DIY khong
# co Control Tower nen khong co AFT. Layer nay lam phan viec do.
#
# ---------------------------------------------------------------
# VI SAO StackSet + Lambda CHU KHONG PHAI PROVIDER ALIAS
#
# Xoa default VPC doi hoi hanh dong BEN TRONG tung account x tung
# region. Terraform can mot provider alias cho moi cap - ma provider
# KHONG sinh dong duoc bang for_each.
#
# 6 account x 2 region = 12 alias viet tay, va account thu 7 la sua
# code. StackSet voi auto_deployment thi account moi TU DUOC don,
# khong phai chay lai gi.
#
# Cung khuon voi config-detective, va khuon do da chay that trong to
# chuc nay.
########################################

provider "aws" {
  region = var.region
  default_tags { tags = local.common_tags }
}

locals {
  common_tags = {
    CostCenter  = var.cost_center
    Owner       = var.owner
    Environment = "shared"
    Project     = var.project
    ManagedBy   = "terraform"
    Repo        = "aws-serverless-applications/landing-zone/account-baseline"
  }

  enabled = var.enable
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_organizations_organization" "this" {}
