########################################
# PIPELINE VENDING ACCOUNT
#
# Chay o ACCOUNT MANAGEMENT. Tu dong hoa nam buoc cua doc 27 thanh
# bay stage, moi stage mot cong duyet.
#
# ---------------------------------------------------------------
# VI SAO BAY STAGE CHO NAM BUOC
#
# Rang buoc thu tu khong bien mat khi bo nguoi ra - no chi thoi can
# nguoi:
#
#   A  account-baseline   tao account
#   B  network            chia se TGW  (can account ID tu A)
#   C  account-baseline   VPC + attachment  (can TGW da chia se tu B)
#   D  network            noi attachment vao route table (can C)
#   E0 config-detective   chinh sach bucket Config o log-archive
#   E  config-detective   excluded_accounts
#   F  permission-sets    accounts_by_scope
#
# E0 tach khoi E vi buoc cho recorder nam GIUA hai cai: recorder can
# chinh sach bucket, ma chinh sach do truoc day do chinh apply cua E
# viet ra - tuc nam sau cai dang cho no. Xem loi 112.
#
# A va C cung mot layer, B va D cung mot layer, E0 va E cung mot
# layer. Lan chay nao khong co account moi thi ca bay stage deu la
# no-op, nen lap lai la re.
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
      Layer       = "vending-pipeline"
      Environment = "prod"
      CostCenter  = var.cost_center
      Owner       = var.owner
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}
