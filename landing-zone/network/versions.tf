terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Backend nam trong backend.tf, do landing-zone/tf-backend/wire-backends.sh
  # sinh ra va nam trong .gitignore. Khong co file do -> state local.
}

########################################
# NETWORK HUB - TGW + security VPC + egress VPC
#
# MAC DINH TAT (enable = false).
#
# ---------------------------------------------------------------
# LAYER NAY TON TIEN THAT, VA TON NHIEU
#
# Moi layer khac trong landing-zone/ deu ~$0/ngay. Layer nay KHONG.
# Doc bang chi phi trong README truoc khi doi enable = true.
#
# Khoan lon nhat la Network Firewall endpoint: ~$0.395/gio MOI AZ,
# tuc ~$285/thang cho mot AZ va ~$570/thang cho hai. No chay 24/7
# du co goi tin nao di qua hay khong.
#
# Vi vay: enable = false, va co check block canh bao khi bat
# firewall o nhieu AZ.
#
# ---------------------------------------------------------------
# PHAM VI - GIAI DOAN 1 THEO DOC 17 MUC 2.1
#
#   CO   TGW + 3 route table + RAM share cho ca to chuc
#   CO   security VPC + AWS Network Firewall + interface endpoint
#   CO   egress VPC + IGW + NAT Gateway
#   CO   noi attachment cua spoke vao dung route table
#
#   CHUA ingress VPC (Palo Alto + F5 can license Marketplace)
#   CHUA 3rd-party VPC + VPN
#   CHUA Route 53 Profile
#
# Doc 17 muc 2.1 noi ro: phan dinh tuyen TGW/security/egress/spoke
# GIU NGUYEN TUNG DONG khi them appliance. Nen lam giai doan 1
# truoc la kiem chung duoc cho kho nhat ma khong phai cho license.
#
# ---------------------------------------------------------------
# VI SAO SPOKE VPC KHONG NAM TRONG LAYER NAY
#
# Spoke VPC nam o account workload, moi account mot provider - ma
# provider KHONG sinh dong duoc bang for_each. Sau account la sau
# alias viet tay, va account thu bay la sua code.
#
# Nen phan chia la:
#   layer nay      TGW (share qua RAM) + hub VPC + route table
#   account workload  tu tao VPC va tu attach vao TGW da share
#   layer nay      noi attachment do vao rtb-spokes + rtb-security
#
# Buoc cuoi bat buoc phai o day: chi CHU SO HUU TGW moi associate
# va propagate duoc. Xem var.spoke_attachments.
########################################

provider "aws" {
  region = var.region
  default_tags { tags = local.common_tags }
}

# Account network - noi dat TGW va toan bo hub VPC.
# Moi resource trong layer nay deu ghi provider = aws.network.
provider "aws" {
  alias  = "network"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${var.network_account_id}:role/${var.cross_account_role}"
  }

  default_tags { tags = local.common_tags }
}

locals {
  common_tags = {
    CostCenter  = var.cost_center
    Owner       = var.owner
    Environment = "shared"
    Project     = var.project
    ManagedBy   = "terraform"
    Repo        = "aws-serverless-applications/landing-zone/network"
  }

  enabled = var.enable

  # AZ -> chi so. Dung de tinh CIDR subnet sao cho khop dung bang
  # o doc 17 muc 3, va de gan NAT/firewall endpoint theo TUNG AZ.
  azs = { for i, z in var.availability_zones : z => i }

  fw = local.enabled && var.enable_firewall ? 1 : 0

  vpce = local.enabled && var.enable_firewall && var.enable_interface_endpoints
}

# Chi khai data source dang DUNG. Ten bucket log lay tu
# var.network_account_id chu khong tu caller identity - vi caller o
# day la MANAGEMENT account, khong phai account network.
data "aws_organizations_organization" "this" {}
