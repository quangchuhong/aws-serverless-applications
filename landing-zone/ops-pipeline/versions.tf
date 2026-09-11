########################################
# PIPELINE VAN HANH CUA SEC - layer organization
#
# Ha tang o ../../modules/tf-pipeline. File nay chi khai provider.
#
# MODULE KHONG KHAI provider, va do la co y: mot provider trong module se
# khoa region va default_tags cho moi caller.
#
# ---------------------------------------------------------------
# BACKEND
#
# Khoa khai o landing-zone/tf-backend/outputs.tf (local.layers),
# backend.tf do wire-backends.sh sinh. KHONG go tay.
#
# LUU Y: layer nay THIEU trong local.layers cho toi 2026-09-11, nen state
# cua no co the dang nam LOCAL. Kiem:
#
#   ls backend.tf && terraform state list | wc -l
#
# Neu chua co backend.tf: `terraform init -migrate-state` va tra loi yes.
# `init` tron voi -input=false cau hinh backend moi ma KHONG chuyen
# state, va plan sau do doi tao lai toan bo. Loi 90.
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
      Layer       = "ops-pipeline"
      Environment = "prod"
      CostCenter  = var.cost_center
      Owner       = var.owner
    }
  }
}
