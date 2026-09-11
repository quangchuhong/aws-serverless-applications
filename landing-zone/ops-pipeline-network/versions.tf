########################################
# PIPELINE VAN HANH: DNS, ENDPOINT, TUONG LUA
#
# Ha tang o ../../modules/tf-pipeline.
#
# ---------------------------------------------------------------
# HAI THU PHAI XONG TRUOC KHI BAT, VA CHUNG KHAC BAN CHAT
#
# 1. STATE DANG RONG. Layer network vua bi xoa de do tien, nen
#    network/ops khong con resource nao. Bat stage se dung o chot chan
#    "state RONG" cua buildspec - va thong bao o do noi ve SAI KHOA
#    STATE, khong noi rang layer chua duoc dung.
#
# 2. LAYER DUOC VIET CHO NGUOI NGOI MAY, CHUA CHO PIPELINE.
#    network/ops/versions.tf dung:
#
#        profile = var.aws_profile != "" ? var.aws_profile : null
#
#    CodeBuild khong co profile. Nen layer se chay bang credential cua
#    role CodeBuild - tuc account MANAGEMENT - va precondition trong
#    main.tf doi chieu account thuc te voi account ghi trong state cua
#    layer cha se DUNG PLAN LAI.
#
#    Do la mot phep chan tot: no khong tao rule group nham vao account
#    chua bucket state. Nhung no cung nghia la layer nay chua pipeline
#    duoc cho toi khi co duong assume_role - giong config-detective va
#    org-trail da co san.
#
# Diem 2 khong sua duoc tu day; no la mot dong trong network/ops.
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
      Layer       = "ops-pipeline-network"
      Environment = "prod"
      CostCenter  = var.cost_center
      Owner       = var.owner
    }
  }
}
