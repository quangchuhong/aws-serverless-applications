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
# ORGANIZATION CLOUDTRAIL
#
# MAC DINH TAT (enable = false).
#
# ---------------------------------------------------------------
# VI SAO CO LAYER NAY
#
# Lop phat hien (config-detective) bat duoc ngay ngay dau:
#   cloud-trail-enabled -> NON_COMPLIANT o MOI account.
#
# To chuc khong co CloudTrail nao, trong khi ba tang khac da chuan
# bi san cho no:
#
#   baseline SCP        chan cloudtrail:StopLogging / DeleteTrail
#   service access      da bat cloudtrail.amazonaws.com
#   lz-auditor          duoc cap quyen doc CloudTrail
#
# Ba tang bao ve va cap quyen cho mot thu khong ton tai. Doc code
# thi khong thay gi sai - vi cai THIEU khong nam o dau de nhin.
#
# ---------------------------------------------------------------
# VI SAO LA ORGANIZATION TRAIL, KHONG PHAI TRAIL TUNG ACCOUNT
#
# Mot trail tao o management account voi is_organization_trail:
#   - phu MOI account hien co
#   - phu MOI account TUONG LAI, khong phai chay lai gi
#   - account con KHONG tat duoc (chi management account sua duoc)
#
# Trail tung account thi nhan len theo so account, va account moi
# se im lang khong co trail cho den khi ai do nho ra.
#
# ---------------------------------------------------------------
# CHI PHI
#
# Ban sao DAU TIEN cua management event: MIEN PHI, moi account.
# Chi tra tien luu tru S3 - vai chuc MB moi thang cho mot to chuc
# nho.
#
# Data event (S3 object, Lambda invoke) thi TINH TIEN theo su kien
# va rat de thanh khoan lon. Mac dinh TAT - xem var.data_events.
########################################

provider "aws" {
  region = var.region
  default_tags { tags = local.common_tags }
}

# Account log archive - S3 nhan log. Tach account de account bi xam
# nhap khong xoa duoc bang chung cua chinh no.
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
    Repo        = "aws-serverless-applications/landing-zone/org-trail"
  }

  enabled = var.enable
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_organizations_organization" "this" {}
