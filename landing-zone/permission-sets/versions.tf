terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  ########################################
  # Remote state
  #
  # Khai rong o day, gia tri that nam trong backend.hcl - file do
  # landing-zone/tf-backend/wire-backends.sh sinh ra.
  #
  #   cd landing-zone/tf-backend && ./wire-backends.sh
  #   cd landing-zone/permission-sets
  #   terraform init -migrate-state -backend-config=backend.hcl
  ########################################

  # backend "s3" {}
}

########################################
# Chay o MANAGEMENT ACCOUNT.
#
# Region PHAI la region dat instance IAM Identity Center,
# khong phai region chay workload. Identity Center chi ton tai
# o DUNG MOT region cho ca organization.
#
# Kiem tra:
#   aws sso-admin list-instances
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
    Environment = "shared"
    Project     = var.project
    ManagedBy   = "terraform"
    Repo        = "aws-serverless-applications/landing-zone/permission-sets"
  }
}

########################################
# Instance Identity Center
#
# LUU Y: Identity Center phai duoc BAT THU CONG MOT LAN trong
# console management account. Terraform khong tao duoc instance,
# chi quan ly duoc permission set ben trong no.
#
# Chua bat -> data source tra ve list rong -> apply loi o dong
# tolist(...)[0]. Do la loi dung, khong phai bug.
########################################

data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}
