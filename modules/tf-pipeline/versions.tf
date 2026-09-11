########################################
# MODULE: PIPELINE VAN HANH
#
# Mot khuon cho MOI pipeline van hanh. Duoc goi tu:
#
#   landing-zone/ops-pipeline/            SCP, OU, tag policy   (sec)
#   landing-zone/ops-pipeline-cloudops/   phan con lai          (cloudops)
#
# =======================================================================
# VI SAO TACH MODULE, VA VI SAO CHI TACH BAY GIO
#
# Bon pipeline gan giong nhau la bon ban sao se lech nhau. Nhung tach
# module som hon thi sai thu tu: `ops-pipeline` la thu duy nhat dang chay
# va da duoc kiem end-to-end, va tach module la doi DIA CHI cua moi
# resource trong no.
#
# ---- CAI BAY: DOI DIA CHI = XOA ROI TAO LAI ----
#
# aws_codepipeline.ops  ->  module.pipeline.aws_codepipeline.ops
#
# Khong co `moved` block thi Terraform doc do la "mot resource bien mat,
# mot resource moi xuat hien" va apply se XOA ROI TAO LAI ca 30 resource
# - gom KMS key (co cua so cho xoa 7-30 ngay, nen tao lai la mot key MOI
# va key cu nam lai cho xoa) va bucket artifact.
#
# Nen caller PHAI mang du 30 `moved` block, va phep kiem la:
#
#   terraform plan   ->  0 to add, 0 to change, 0 to destroy
#
# Bat ky con so khac 0 nao la dau hieu mot `moved` bi thieu. KHONG apply
# khi thay so khac.
#
# =======================================================================
# THU KHONG NAM TRONG MODULE, VA VI SAO
#
#   provider "aws"      caller khai. Module khong duoc khai provider:
#                       lam vay se khoa tag va region cho moi caller.
#   quyen cua dich vu   var.quyen_dich_vu / var.tu_choi_dich_vu. Ranh
#                       gioi ghi KHAC NHAU o moi pipeline, va no phai nam
#                       canh danh sach stage de nguoi review thay cung
#                       luc. Xem iam.tf.
#   danh sach stage     var.stages. Day la phan KHAI BAO cua tung
#                       pipeline, kem ly do cho tung dong.
#   gate.py             landing-zone/ops-gate/ - MOT ban cho moi
#                       pipeline. Bang LUAT la chinh sach an ninh; hai
#                       ban sao se lech, va ban lech se la ban long hon.
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

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
