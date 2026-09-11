########################################
# PIPELINE VAN HANH: CLOUDTRAIL TO CHUC
#
# Ha tang o ../../modules/tf-pipeline.
#
# ---------------------------------------------------------------
# CHO ROLE LIEN ACCOUNT
#
# Bucket log nam o ACCOUNT LOG-ARCHIVE - org-trail/versions.tf:69 ghi
# assume sang arn:aws:iam::<log-archive>:role/<cross_account_role>.
# Cung tinh trang voi config-rules: hom nay chi co
# OrganizationAccountAccessRole.
#
# ---------------------------------------------------------------
# VI SAO MOT PIPELINE RIENG CHO MOT LAYER GAN NHU KHONG DOI
#
# CloudTrail doi vai lan mot nam. Mot pipeline cho no khong phai de chay
# thuong xuyen - la de hai thu khac:
#
#   1. DRIFT. CodeBuild drift chay `plan -lock=false` hang dem. Voi
#      trail, mot lan plan ra KHAC "khong co thay doi" nghia la co nguoi
#      vua cham vao thu duy nhat tra loi duoc "ai da lam gi".
#   2. Ranh gioi ghi rieng. Role cua pipeline nay khong dung chung voi
#      pipeline nao khac, nen no khong the sua Config rule hay
#      permission set.
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
      Layer       = "ops-pipeline-trail"
      Environment = "prod"
      CostCenter  = var.cost_center
      Owner       = var.owner
    }
  }
}
