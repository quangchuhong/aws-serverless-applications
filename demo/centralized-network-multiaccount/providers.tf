terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

########################################
# TAG CHUAN - dung chung cho CA BA account
#
# Bon tag dau la tag bat buoc theo doc 11 muc 2, va la nhung tag
# duoc bat cost allocation o landing-zone/billing-guard.
#
# Multi-account co diem dang chu y: cost allocation tag bat MOT LAN
# o management account nhung ap dung cho MOI account con. Nen ca ba
# provider ben duoi deu phai gan cung bo tag, neu khong se co account
# lot khoi bao cao chi phi theo tag.
########################################

locals {
  common_tags = {
    CostCenter  = var.cost_center
    Owner       = var.owner
    Environment = var.environment
    Project     = var.project

    ManagedBy = "terraform"
    Repo      = "aws-serverless-applications/demo/centralized-network-multiaccount"
    Ephemeral = "true"
  }
}

########################################
# Terraform KHONG cho for_each tren provider.
# Do do moi account phai co mot provider alias khai bao tuong minh.
# Them spoke thu ba = them mot khoi provider + mot module block.
########################################

# Chay tu day: management account (hoac bat ky account nao assume duoc cac role duoi)
provider "aws" {
  region = var.region
  default_tags { tags = local.common_tags }
}

provider "aws" {
  alias  = "network"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${var.network_account_id}:role/${var.execution_role_name}"
  }

  default_tags { tags = local.common_tags }
}

provider "aws" {
  alias  = "spoke_a"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${var.spoke_a_account_id}:role/${var.execution_role_name}"
  }

  default_tags { tags = local.common_tags }
}

provider "aws" {
  alias  = "spoke_b"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${var.spoke_b_account_id}:role/${var.execution_role_name}"
  }

  default_tags { tags = local.common_tags }
}
