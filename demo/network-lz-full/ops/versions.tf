########################################
# LOP VAN HANH MANG - state RIENG
#
# Layer cha (../) so huu TGW, security VPC, firewall, va moi VPC.
# No doi vai thang mot nam.
#
# Layer nay so huu bon thu doi HANG NGAY:
#
#   1. Rule firewall east-west   ai duoc goi ai, port nao
#   2. Route ngoai le trong TGW  blackhole, duong toi doi tac
#   3. Interface endpoint        them/bot dich vu AWS tap trung
#   4. Ban ghi DNS noi bo        ten trong PHZ tap trung
#
# TACH LAM HAI STATE LA CA THIET KE, khong phai cho gon file.
#
# Gop chung thi mo mot port la mot `terraform plan` cham vao hon 200
# resource: firewall, NAT, moi subnet, moi stack instance cross-account.
# Nguoi duyet phai doc het de biet plan do KHONG lam gi khac ngoai
# them mot dong rule. Lam vay moi ngay thi khong ai doc that, va den
# mot ngay co nguoi bam yes qua nhanh - dung luc plan do chua mot
# thay doi khong ai de y.
#
# Tach ra thi plan cua lop nay cham vao dung 4 loai resource. Kich ban
# xau nhat cua mot lan apply sai o day la mot rule sai hoac mot ban
# ghi DNS sai - sua bang mot commit. Khong lan nao cham duoc vao
# firewall endpoint hay route mac dinh, vi chung khong nam trong state
# nay.
#
# DOI LAI: hai lop phai khop nhau o MOT diem - var.ops_rule_group_arns
# ben layer cha. Xem README.md muc "Bootstrap".
########################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 5.60 de co aws_route53profiles_* - endpoint moi phai duoc
      # gan vao Profile, neu khong thi account khac khong phan giai
      # duoc ten dich vu vua them.
      version = ">= 5.60, < 6.0"
    }
  }
}

provider "aws" {
  region = local.hub.region

  default_tags {
    tags = {
      Project   = local.hub.project
      ManagedBy = "terraform"
      Repo      = "aws-serverless-applications/demo/network-lz-full/ops"

      # Phan biet voi resource cua layer cha khi doc Cost Explorer hay
      # khi quet tag luc go bo.
      Layer = "network-ops"
    }
  }
}
