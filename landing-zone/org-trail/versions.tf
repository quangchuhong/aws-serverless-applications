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

####################################
# Environment CHI CO BON GIA TRI
#
# "dev" / "staging" / "prod" / "sandbox" - doc 11 muc 2, va khai o
# organization/variables.tf:346 (allowed_values cua tag policy).
# "shared" KHONG nam trong do va khong bao gio nam trong do.
#
# Ha tang quan tri lay "prod": no khong phai moi truong thu nghiem, va
# mat no la mat ban ghi "ai da lam gi".
#
# CAU TRUOC O DAY GHI '"shared" bi tag policy tu choi' - va cau do SAI.
# Tag policy chua duoc tao (output tag_policy cua layer organization:
# enabled = false, policy_id = null; stage sec-tagging dang tat). Nen
# khong co gi TU CHOI "shared" ca - da co mot trail va mot bucket log
# mang dung tag do trong nhieu ngay, va thu tim ra chung la mot ban plan,
# khong phai mot phep tu choi.
#
# Bon gia tri tren la mot quy uoc DUOC TON TRONG, chua phai mot quy uoc
# DUOC THUC THI. Sua lai dong nay khi sec-tagging bat len.
####################################
locals {
  common_tags = {
    CostCenter  = var.cost_center
    Owner       = var.owner
    Environment = "prod"
    Project     = var.project
    ManagedBy   = "terraform"
    Repo        = "aws-serverless-applications/landing-zone/org-trail"
  }

  enabled = var.enable
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_organizations_organization" "this" {}
