########################################
# PIPELINE VAN HANH: AI VAO ACCOUNT NAO
#
# Chay o ACCOUNT MANAGEMENT - noi IAM Identity Center duoc quan tri.
#
# Ha tang o ../../modules/tf-pipeline. File main.tf chi khai stage,
# catalog va RANH GIOI GHI.
#
# ---------------------------------------------------------------
# PIPELINE DUY NHAT TRONG BON CAI KHONG CAN ROLE LIEN ACCOUNT
#
# landing-zone/permission-sets khong co provider assume_role nao - no
# chay ngay trong account management. Nen day la pipeline van hanh dau
# tien sau SCP co the bat len va do duoc, truoc khi viec "role rieng day
# xuong bang StackSet" xong.
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
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      ManagedBy   = "terraform"
      Layer       = "ops-pipeline-permission-set"
      Environment = "prod"
      CostCenter  = var.cost_center
      Owner       = var.owner
    }
  }
}
