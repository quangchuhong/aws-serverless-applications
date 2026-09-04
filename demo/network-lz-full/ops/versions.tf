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

  ########################################
  # BACKEND - do wire-backends.sh sinh ra, KHONG khai o day
  #
  # Lop nay la mot layer nhu moi layer khac cua landing zone. Key cua
  # no khai o landing-zone/tf-backend/outputs.tf (local.layers):
  #
  #   "demo/network-lz-full/ops" = "demo-network-lz-full/ops/terraform.tfstate"
  #
  # CUNG PREFIX voi layer cha. Bat buoc, khong phai cho gon: bucket
  # policy cap quyen theo prefix, nen mot prefix moi la khong co dong
  # Allow nao phu - va init bao 403 ma khong nhac gi toi prefix.
  #
  # Noi backend:
  #
  #   cd landing-zone/tf-backend
  #   terraform apply                 # 0 resource doi, chi Outputs
  #   ./wire-backends.sh              # ghi backend.tf + backend.hcl
  #   cd demo/network-lz-full/ops
  #   terraform init -backend-config=backend.hcl
  #
  # DUNG go tay mot khoi backend "s3" vao file nay: wire-backends.sh
  # ghi backend.tf rieng, va hai khoi backend trong mot module la loi.
  #
  # Layer nay co BACKEND va RESOURCE o hai account khac nhau, nen no
  # can them mot dong o landing-zone/tf-backend/terraform.tfvars:
  #
  #   backend_profiles = {
  #     "demo/network-lz-full"     = "default"
  #     "demo/network-lz-full/ops" = "default"
  #   }
  #
  # VI SAO PHAI CO BACKEND TU XA
  #
  # State nay giu ARN cua rule group ma firewall policy dang tham
  # chieu. Mat no la mat quyen sua va quyen xoa mot resource van dang
  # chay - Terraform se doi tao rule group thu hai, con cai cu nam lai
  # vinh vien khong ai quan.
  #
  # Va state local nghia la khong co khoa: hai nguoi cung sua catalog
  # thi nguoi apply sau ghi de nguoi truoc, khong ben nao thay diff.
  ########################################

# backend "s3" {
#   bucket       = "qh11-lz-tfstate-609320954321"
#   key          = "demo-network-lz-full/ops/terraform.tfstate"
#   region       = "ap-southeast-1"
#   use_lockfile = true
# }
  

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

  # Profile de TAO RESOURCE - khac profile trong khoi backend o tren.
  #
  # Backend noi state nam o dau (co the la account management). Dong
  # nay noi ha tang duoc tao o dau (account network). Gop hai thu do
  # lam mot la cach chac chan nhat de mot ngay nao do rule group xuat
  # hien trong account chua bucket state.
  #
  # De trong = dung chuoi giai credential mac dinh. Nho rang BIEN MOI
  # TRUONG DUNG TRUOC profile trong chuoi do: co AWS_ACCESS_KEY_ID
  # trong shell thi dong nay bi bo qua ma khong co gi bao.
  #
  # Precondition trong main.tf doi chieu account thuc te voi account
  # ghi trong state cua layer cha, nen lech la plan dung lai.
  profile = var.aws_profile != "" ? var.aws_profile : null

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


