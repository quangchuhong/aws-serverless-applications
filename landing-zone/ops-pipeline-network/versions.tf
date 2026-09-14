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
# 2. (DA XU LY) LAYER TUNG DUOC VIET CHO NGUOI NGOI MAY.
#    network/ops/versions.tf tung dung:
#
#        profile = var.aws_profile != "" ? var.aws_profile : null
#
#    Khoi nay du doan DUNG rang do la cho se hong, va ghi "khong sua
#    duoc tu day". Dung - no la mot dong trong network/ops, va gio dong
#    do da co dieu kien loai tru:
#
#        profile = var.assume_role_arn == "" && var.aws_profile != ""
#                  ? var.aws_profile : null
#
#    HAU QUA THAT khac du doan o tren mot chut, va dang ghi lai: du doan
#    la layer se chay bang credential CodeBuild roi bi precondition chan.
#    Thuc te no vo SOM HON - Terraform giai profile TRUOC khi assume, va
#    lan chay dau cua pipeline chet o
#
#        Error: failed to get shared config profile, default
#
#    tuc no khong bao gio den duoc precondition. Mot du doan dung ve CHO
#    hong nhung sai ve CACH hong van dan nguoi doc di dung huong - nhung
#    thong bao thi khong giong thu ho cho.
#
#    Vi sao aws_profile lai co mat trong CodeBuild: no nam trong
#    terraform.tfvars, ma push-tfvars.sh day CHINH file do len S3 cho
#    pipeline doc. Mot bien danh cho nguoi ngoi may di thang vao mot noi
#    khong co ~/.aws/config.
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
