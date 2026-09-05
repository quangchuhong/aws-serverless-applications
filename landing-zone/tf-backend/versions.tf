terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  ########################################
  # KHONG co backend block o day - CO Y.
  #
  # Backend nam trong backend.tf, do ./wire-backends.sh sinh ra va
  # nam trong .gitignore.
  #
  # VI SAO tach ra file rieng:
  #
  #   1. VONG LAP CON GA - QUA TRUNG. Layer nay TAO RA bucket chua
  #      state, nen lan dau bat buoc chay bang state LOCAL. Khong co
  #      backend.tf -> tu dong la local. Dung nhat, khong phai nho.
  #
  #   2. File nay duoc GIT TRACK. Sua no de bat backend nghia la
  #      commit mot thay doi rieng cua may ban - va se dung do voi
  #      nguoi khac, hoac lam hong luot dung dau tien cua chinh ban
  #      o lan clone sau.
  #
  # Thu tu:
  #   terraform init && terraform apply     (state local)
  #   ./wire-backends.sh                    (sinh backend.tf + backend.hcl)
  #   terraform init -migrate-state -backend-config=backend.hcl
  ########################################
}

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
    Repo        = "aws-serverless-applications/landing-zone/tf-backend"

    # KHONG co Ephemeral=true. Day la ha tang thuong truc - xoa no di
    # la moi layer khac mat state.
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
