terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  ########################################
  # VONG LAP CON GA - QUA TRUNG
  #
  # Layer nay TAO RA cho chua state. Lan dau chay no chua co cho de
  # cat state cua chinh minh -> phai dung state LOCAL.
  #
  # Sau khi apply xong moi quay lai tro backend ve chinh cai bucket
  # vua tao (xem README muc 2, buoc 3).
  #
  # Dung buoc do thi state cua layer nay nam tren may ban - mat may
  # la mat quyen quan ly bucket state cua ca to chuc.
  ########################################

  #####################################################################
  #                                                                   #
  #   DUNG BO COMMENT DONG DUOI KHI CHUA CHAY terraform apply         #
  #                                                                   #
  #   Bo som -> terraform init doi ban nhap bucket name, va moi lenh  #
  #   sau do bao "Backend initialization required".                   #
  #                                                                   #
  #   Bucket duoc tao BOI CHINH layer nay. Chua apply thi no chua     #
  #   ton tai.                                                        #
  #                                                                   #
  #   Thu tu dung:                                                    #
  #     1. terraform init          (state local)                      #
  #     2. terraform apply         <- bucket ra doi o day             #
  #     3. ./wire-backends.sh      (sinh backend.hcl)                 #
  #     4. BO COMMENT dong duoi                                       #
  #     5. terraform init -migrate-state -backend-config=backend.hcl  #
  #                                                                   #
  #   Li o buoc nao thi: comment lai, terraform init -reconfigure,    #
  #   roi lam lai tu buoc 2. Khong mat gi.                            #
  #                                                                   #
  #####################################################################

  # backend "s3" {}
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
    Environment = "shared"
    Project     = var.project
    ManagedBy   = "terraform"
    Repo        = "aws-serverless-applications/landing-zone/tf-backend"

    # KHONG co Ephemeral=true. Day la ha tang thuong truc - xoa no di
    # la moi layer khac mat state.
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
