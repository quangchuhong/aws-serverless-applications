terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  common_tags = {
    Project   = var.project
    ManagedBy = "terraform"
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
