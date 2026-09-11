########################################
# PIPELINE VAN HANH: CONFIG RULE
#
# Ha tang o ../../modules/tf-pipeline.
#
# ---------------------------------------------------------------
# CHO ROLE LIEN ACCOUNT
#
# Config rule song o ACCOUNT SECURITY - config-detective/aggregator-rules.tf
# ghi `provider = aws.security`, va provider do assume sang
# arn:aws:iam::<security>:role/<cross_account_role>.
#
# Hom nay o account do chi co OrganizationAccountAccessRole, tuc FULL
# ADMIN. Cap cho pipeline quyen assume vao do de sua Config rule la cap
# quyen sua MOI THU trong account bao mat.
#
# Duong dung: mot role rieng cho pipeline, day xuong bang CloudFormation
# StackSet, chi co quyen tren Config. Viec do da hoan lai den sau phep do
# app-prod-5.
#
# Do la ly do enable = false o terraform.tfvars.example, va ly do stage
# duoc khai enabled = false.
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
      Layer       = "ops-pipeline-config-rules"
      Environment = "prod"
      CostCenter  = var.cost_center
      Owner       = var.owner
    }
  }
}
