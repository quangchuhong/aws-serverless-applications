terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Backend nam trong backend.tf, do landing-zone/tf-backend/wire-backends.sh
  # sinh ra va nam trong .gitignore. Khong co file do -> state local.
}

########################################
# LOP PHAT HIEN - AWS Config
#
# MAC DINH TAT (enable = false).
#
# ---------------------------------------------------------------
# VI SAO CO LAYER NAY
#
# SCP o landing-zone/organization NGAN hanh dong. No khong tra loi
# duoc "hien tai co bao nhieu resource dang sai".
#
#   SCP          : chan CreateInternetGateway
#   Config rule  : phat hien IGW DANG TON TAI
#
# Hai lop bu cho nhau. Danh sach resource_types mac dinh duoc chon
# doi xung voi 4 SCP ben layer organization.
#
# ---------------------------------------------------------------
# CHI PHI - DOC TRUOC KHI BAT
#
# Config tinh theo configuration item ghi duoc + rule evaluation.
# Bon can gat, theo thu tu tac dong:
#
#   1. recording_frequency = "DAILY"   <- lon nhat
#   2. Chon account   (bo Dev/Sandbox)
#   3. Chon region    (Config la per-region)
#   4. Chon resource type (KHONG dung all_supported)
#
# Mac dinh cua layer nay da dat ca bon o muc tiet kiem.
########################################

provider "aws" {
  region = var.region
  default_tags { tags = local.common_tags }
}

# Account security tooling - aggregator, Security Hub, canh bao
provider "aws" {
  alias  = "security"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${var.security_account_id}:role/${var.cross_account_role}"
  }

  default_tags { tags = local.common_tags }
}

# Account log archive - S3 nhan snapshot
provider "aws" {
  alias  = "log_archive"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${var.log_archive_account_id}:role/${var.cross_account_role}"
  }

  default_tags { tags = local.common_tags }
}

locals {
  common_tags = {
    CostCenter  = var.cost_center
    Owner       = var.owner
    Environment = "prod" # ha tang quan tri - "shared" bi tag policy tu choi
    Project     = var.project
    ManagedBy   = "terraform"
    Repo        = "aws-serverless-applications/landing-zone/config-detective"
  }

  enabled = var.enable
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
