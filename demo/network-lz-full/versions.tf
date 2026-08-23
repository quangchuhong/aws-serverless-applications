terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 5.16 de NLB nhan security_groups (dung cho khoa origin o cdn.tf)
      # >= 5.60 de co aws_route53profiles_* (dns.tf)
      #
      # Lock file cu hon 5.60 thi init bao loi ro rang. Chay:
      #   terraform init -upgrade
      version = ">= 5.60, < 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

########################################
# TAG CHUAN
#
# Bon tag dau la tag BAT BUOC theo doc 11 muc 2, va cung la
# nhung tag duoc bat cost allocation o landing-zone/billing-guard.
#
# Neu resource khong mang tag nay thi Cost Explorer khong group
# theo chung duoc - bat cost allocation tag ma khong gan tag
# la lam mot nua cong viec.
########################################

locals {
  common_tags = merge(
    {
      CostCenter  = var.cost_center
      Owner       = var.owner
      Environment = var.environment
      Project     = var.project

      ManagedBy = "terraform"
      Repo      = "aws-serverless-applications/demo/network-lz-full"
    },

    # Danh dau resource se bi xoa. teardown.sh QUET THEO TAG NAY va
    # xoa moi thu mang no - ke ca resource khong con trong state.
    #
    # Vi vay ephemeral = false BO HAN tag: neu ban giu bo nay lam mang
    # that thi tag Ephemeral la mot lenh xoa dang cho nguoi bam.
    var.ephemeral ? { Ephemeral = "true" } : {},
  )
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}
