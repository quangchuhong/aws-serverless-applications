########################################
# BIEN
########################################

variable "enable" {
  description = <<-EOT
    MAC DINH TAT.

    Bat pipeline nay nghia la tao mot duong tu dong co quyen apply
    bon layer, trong do co layer network. Do la mot thay doi ve mo
    hinh van hanh, khong phai mot resource them vao.
  EOT
  type        = bool
  default     = false
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project" {
  type    = string
  default = "lz"
}

variable "cost_center" {
  type = string
}

variable "owner" {
  type = string
}

########################################
# 1. NGUON
########################################

variable "source_type" {
  description = <<-EOT
    Nguon lay code.

      "codecommit"  repo CodeCommit trong chinh account nay
      "s3"          zip do mot he thong khac day len

    CodeStar Connection (GitHub) chua lam - them vao day khi can.

    LUU Y VE CODECOMMIT: AWS ngung nhan khach hang MOI tu giua 2024.
    Account nao da co repo tu truoc thi van dung duoc binh thuong.
    Kiem:
      aws codecommit list-repositories --region <region>
  EOT
  type        = string
  default     = "codecommit"

  validation {
    condition     = contains(["codecommit", "s3"], var.source_type)
    error_message = "source_type phai la \"codecommit\" hoac \"s3\"."
  }
}

variable "repository_name" {
  description = "Ten repo CodeCommit. Layer nay KHONG tao repo - no tro toi repo da co."
  type        = string
  default     = ""
}

variable "branch_name" {
  description = <<-EOT
    Nhanh kich hoat pipeline.

    Dat la nhanh mac dinh cua repo. Mot nhanh khong ai merge vao la
    mot pipeline khong bao gio chay, va do la kieu hong khong ai bao.
  EOT
  type        = string
  default     = "main"
}

variable "source_bucket" {
  description = "Chi dung khi source_type = \"s3\". Bucket chua zip nguon."
  type        = string
  default     = ""
}

variable "source_object_key" {
  description = "Chi dung khi source_type = \"s3\"."
  type        = string
  default     = "vending/source.zip"
}

########################################
# 2. STATE - CACH PIPELINE NOI VAO CAC LAYER
#
# backend.tf va backend.hcl deu NAM TRONG .gitignore, co y: chung do
# wire-backends.sh sinh ra tren may tung nguoi.
#
# Hau qua voi CodeBuild: source checkout ra KHONG CO khoi backend nao.
# `terraform init` se cau hinh backend LOCAL, tuc mot state rong, va
# `plan` bao can tao moi ~200 resource. Nguoi duyet nhin con so do co
# the tuong day la mot moi truong moi.
#
# Nen buildspec TU SINH backend.tf truoc khi init, tu ba gia tri duoi
# day. Xem templates/buildspec-terraform.yml.tftpl.
########################################

variable "state_bucket" {
  description = <<-EOT
    Bucket chua state cua cac layer.

      cd ../tf-backend && terraform output bucket
  EOT
  type        = string
}

variable "state_lock_table" {
  description = <<-EOT
    Bang DynamoDB dung de khoa state. De rong neu lock_mode = "s3".

      cd ../tf-backend && terraform output lock_table

    LUU Y: bang khoa duoc dia chi bang TEN, va mot ten luon duoc giai
    trong account CUA NGUOI GOI. Pipeline chay o management - cung
    account voi bang - nen khong vuong loi 90.
  EOT
  type        = string
  default     = ""
}

variable "layer_keys" {
  description = <<-EOT
    Duong dan layer -> khoa state trong bucket.

      cd ../tf-backend && terraform output layers

    PHAI khop CHINH XAC. Sai khoa thi Terraform mo mot state RONG o
    duong dan moi: plan doi tao lai toan bo, va ha tang that thanh mo
    coi - van chay, van tinh tien, khong con ai quan.

    Chu y layer network trong ban trien khai nay dung mot khoa KHONG
    khop duong dan (di san tu demo/network-lz-full). Dung doan.
  EOT
  type        = map(string)

  validation {
    condition = alltrue([
      for d in ["landing-zone/account-baseline", "landing-zone/network",
      "landing-zone/config-detective", "landing-zone/permission-sets"] :
      contains(keys(var.layer_keys), d)
    ])
    error_message = "layer_keys phai co du bon layer: account-baseline, network, config-detective, permission-sets."
  }
}

variable "network_deploy_role_arn" {
  description = <<-EOT
    Role o ACCOUNT MANG ma CodeBuild assume o stage B va D.

      cd ../network && terraform output pipeline_deploy_role_arn

    Role do chi ton tai khi ben kia da khai pipeline_trusted_role_arns
    tro ve role CodeBuild cua layer nay - tuc hai ben tro vao nhau, va
    phai apply theo thu tu: layer nay truoc (de co ARN), roi network,
    roi lai layer nay.

    DE RONG = bo hai stage network khoi pipeline. Bon stage con lai
    van chay, va buoc 2 voi buoc 5 lam tay nhu doc 27.
  EOT
  type        = string
  default     = ""
}

########################################
# 3. DUYET
########################################

variable "approval_emails" {
  description = <<-EOT
    Dia chi nhan thu khi mot stage cho duyet.

    DE RONG thi cong duyet VAN chay - no van chan pipeline - chi la
    khong ai duoc bao, va nguoi ta phai tu mo console ra xem. Mot
    pipeline dung im cho duyet ma khong goi ai se bi coi la hong.

    Moi dia chi phai bam xac nhan trong thu dau tien SNS gui toi.
  EOT
  type        = list(string)
  default     = []
}

########################################
# 4. NGUONG
########################################

variable "build_timeout_minutes" {
  description = <<-EOT
    Gioi han moi lan chay CodeBuild.

    Layer network apply mat ~20-30 phut khi dung ca Network Firewall,
    va StackSet cross-account cham hon nua. 60 la de co bien.
  EOT
  type        = number
  default     = 60

  validation {
    condition     = var.build_timeout_minutes >= 10 && var.build_timeout_minutes <= 480
    error_message = "build_timeout_minutes trong khoang 10..480."
  }
}

variable "wait_attachment_minutes" {
  description = <<-EOT
    Cho toi da bao lau de TGW attachment chuyen sang `available`.

    Giua stage C (tao attachment) va stage D (noi vao route table),
    attachment cross-account mat khoang mot phut de doi trang thai.
    Data source cua layer network loc `state = available`, nen chay
    som thi no khong thay gi va khong noi gi - dung cai da xay ra
    hom 6/9 va bi chua bang mot lan apply thu hai.

    Stage cho nay HOI TRANG THAI THAT chu khong ngu mot khoang co
    dinh: ngu du lau van co the som, va ngu qua lau la tra tien cho
    mot cai may khong lam gi.
  EOT
  type        = number
  default     = 10
}

variable "log_retention_days" {
  type    = number
  default = 90
}
