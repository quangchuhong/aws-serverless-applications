########################################
# CHOT DUYET CHO REPO CODECOMMIT
#
# Chay o ACCOUNT MANAGEMENT - noi repo diy-aws-landing-zone nam.
#
# ---------------------------------------------------------------
# VI SAO LAYER NAY TON TAI
#
# ops-pipeline/main.tf viet rang pipeline van hanh KHONG can cong duyet,
# va ly do neu ra la "cho duyet dung la PR tren git". Do duoc rang lop
# bu do CHUA TON TAI:
#
#   git log --merges   chi co merge tu-nhanh, chua co PR nao
#   duong len repo     `git push codecommit HEAD:main` = PUSH TRUC TIEP
#
# Ban dau toi them .github/CODEOWNERS. Sai cho: cong ty khong dung
# GitHub, nen file do la mot lop chan khong bao gio chay. Da xoa.
#
# Cong ty dung CodeCommit noi bo, nen phep chan phai la cua CodeCommit:
# approval rule template.
#
# ---------------------------------------------------------------
# REPO KHONG DO TERRAFORM QUAN
#
# Khong co aws_codecommit_repository o bat ky layer nao - repo duoc tao
# tay, va hai pipeline chi tham chieu theo TEN. Layer nay giu nguyen the:
# no khong import repo, chi gan template vao no.
#
# Nghia la `terraform destroy` o day KHONG xoa repo. Do la co y.
#
# ---------------------------------------------------------------
# BACKEND
#
# Nhu moi layer khac: khoa khai o landing-zone/tf-backend/outputs.tf,
# backend.tf do wire-backends.sh sinh. KHONG go tay.
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
      Layer       = "codecommit-guard"
      Environment = "prod"
      CostCenter  = var.cost_center
      Owner       = var.owner
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
