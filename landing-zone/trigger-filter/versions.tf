########################################
# BO LOC KICH HOAT
#
# Chay o ACCOUNT MANAGEMENT - cung account voi CodeCommit va moi pipeline
# van hanh.
#
# ---------------------------------------------------------------
# VAN DE NO GIAI
#
# Moi pipeline truoc day co mot rule EventBridge rieng bat "co commit vao
# nhanh main". Rule do KHONG loc duoc theo duong dan, vi su kien
# "CodeCommit Repository State Change" khong mang danh sach file - no chi
# co repositoryName, commitId, oldCommitId, referenceName.
#
# Hau qua: sua mot dong trong docs/ cung lam pipeline vending chay, va
# pipeline vending la cai dung bay stage vending account.
#
# (CodePipeline V2 co bo loc duong dan, nhung chi cho nguon kieu
# connection - GitHub, GitLab, Bitbucket. Cong ty chi dung CodeCommit noi
# bo, nen duong do khong mo.)
#
# Cach duy nhat con lai la mot ham dung GIUA: no co hai commit id, goi
# GetDifferences, roi khoi dong dung nhung pipeline co duong dan bi cham.
#
# ---------------------------------------------------------------
# THU TU BAT - QUAN TRONG, VA MOT CHIEU NGUY HIEM HON CHIEU KIA
#
#   BAT layer nay TRUOC, roi moi tat rule rieng cua tung pipeline.
#
# Lam nguoc lai (tat rule rieng truoc) thi giua hai lan apply KHONG CO
# duong nao kich hoat pipeline nao - va do la kieu hong im lang: moi thu
# xanh, chi la khong bao gio chay.
#
# Lam dung thu tu thi giua hai lan apply moi pipeline bi kich hoat HAI
# lan. Vo hai: CodePipeline thay the ban dang cho bang ban moi.
#
# ---------------------------------------------------------------
# BACKEND
#
# Khoa khai o landing-zone/tf-backend/outputs.tf (local.layers),
# backend.tf do wire-backends.sh sinh. KHONG go tay.
########################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60, < 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      ManagedBy   = "terraform"
      Layer       = "trigger-filter"
      Environment = "prod"
      CostCenter  = var.cost_center
      Owner       = var.owner
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
