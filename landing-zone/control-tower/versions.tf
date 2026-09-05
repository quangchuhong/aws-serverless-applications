terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      # aws_controltower_landing_zone can provider tuong doi moi.
      # Bao khong nhan resource nay thi nang provider truoc khi nghi
      # den nguyen nhan khac.
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # Backend nam trong backend.tf, do landing-zone/tf-backend/wire-backends.sh
  # sinh ra va nam trong .gitignore. Khong co file do -> state local.
}

########################################
# BAN CONTROL TOWER - DE DOI CHIEU
#
# MAC DINH TAT (enable_landing_zone = false).
#
# Muc dich: viet san va kiem chung bang terraform plan, giong cach
# da lam voi Palo Alto / F5 trong demo/network-lz-full/appliances.tf.
#
# Ban DUNG THAT cho lab la ../organization/ (DIY).
#
# ---------------------------------------------------------------
# TRUOC KHI BAT, BIET BA DIEU:
#
# 1. CHI PHI THUONG TRUC. Control Tower mien phi nhung BAT AWS Config
#    o moi account x moi governed region. Config tinh theo
#    configuration item + rule evaluation. Day la khoan CHAY LIEN TUC,
#    khong tat duoc neu con dung CT.
#
# 2. KHONG XOA DUOC THEO BUOI. Decommission Control Tower la quy
#    trinh thu cong, nhieu buoc. Mo hinh dung-xoa cua repo nay
#    khong ap dung cho no.
#
# 3. KHONG DAO NGUOC DE DANG. Dang ky OU san co vao CT se day
#    StackSet baseline xuong MOI account trong OU do.
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
    Environment = "prod" # ha tang quan tri - "shared" bi tag policy tu choi
    Project     = var.project
    ManagedBy   = "terraform"
    Repo        = "aws-serverless-applications/landing-zone/control-tower"
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
