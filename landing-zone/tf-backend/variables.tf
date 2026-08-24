variable "region" {
  description = <<-EOT
    Region dat bucket state.

    Nen dung MOT region duy nhat cho state cua ca to chuc, ke ca khi
    workload chay o nhieu region - state khong can gan workload, va
    gom mot cho thi backup/audit de hon.
  EOT
  type        = string
  default     = "ap-southeast-1"
}

variable "prefix" {
  description = <<-EOT
    Tien to ten bucket. Ten cuoi cung se la:
      <prefix>-tfstate-<account_id>

    Kem account ID vi ten bucket S3 phai DUY NHAT TOAN CAU - khong
    phai duy nhat trong account ban.
  EOT
  type        = string
  default     = "acme-lz"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$", var.prefix))
    error_message = "prefix chi gom chu thuong, so va dau gach ngang."
  }
}

variable "project" {
  type    = string
  default = "acme-lz"
}

variable "cost_center" {
  type    = string
  default = "CC-0000"
}

variable "owner" {
  type    = string
  default = "platform@example.com"
}

########################################
# 1. Khoa state
########################################

variable "lock_mode" {
  description = <<-EOT
    Cach khoa state khi co nhieu nguoi cung apply.

      "dynamodb" - bang DynamoDB. Chay voi MOI phien ban Terraform.
                   Chi phi ~$0 voi PAY_PER_REQUEST.

      "s3"       - khoa bang chinh S3 (conditional write).
                   CAN TERRAFORM >= 1.10. Khong ton them resource nao.
                   Khi do backend khai use_lockfile = true.

      "both"     - tao ca bang DynamoDB nhung backend dung lockfile.
                   Dung khi dang chuyen doi dan, co layer cu con
                   tro toi DynamoDB.

    Khong co khoa thi hai nguoi apply cung luc se lam HONG state -
    day khong phai rui ro ly thuyet, no xay ra rat nhanh khi co doi.
  EOT
  type        = string
  default     = "dynamodb"

  validation {
    condition     = contains(["dynamodb", "s3", "both"], var.lock_mode)
    error_message = "lock_mode phai la: dynamodb, s3, hoac both."
  }
}

########################################
# 2. Ma hoa
########################################

variable "use_kms_cmk" {
  description = <<-EOT
    true  = tao KMS customer-managed key rieng cho state (~$1/thang
            + phi request).
    false = dung SSE-S3 (AES256), MIEN PHI.

    CA HAI DEU MA HOA THAT o muc luu tru. Khac biet la quyen quan ly
    khoa:

      SSE-S3  : AWS giu khoa. Ai co quyen doc bucket la doc duoc state.
      KMS CMK : them mot lop quyen doc lap. Thu hoi quyen tren key
                la chan duoc doc state ngay ca khi con quyen S3.
                Co CloudTrail rieng cho tung lan dung khoa.

    Bat khi state bat dau chua thong tin nhay cam - mat khau RDS,
    khoa API sinh boi Terraform. Voi hai layer hien tai (billing-guard,
    permission-sets) thi state khong chua bi mat nao.
  EOT
  type        = bool
  default     = false
}

########################################
# 3. Giu lich su
########################################

variable "noncurrent_version_retention_days" {
  description = <<-EOT
    Giu ban state cu bao nhieu ngay.

    Versioning la thu CUU BAN khi apply nham: quay lai ban truoc do
    duoc. Nhung moi lan apply deu sinh mot version moi, de lau khong
    don thi phinh dan.

    90 ngay la can bang hop ly. Dat thap hon 30 thi mat kha nang
    khoi phuc nhung su co phat hien muon.
  EOT
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_retention_days >= 7
    error_message = "Duoi 7 ngay la qua ngan de khoi phuc duoc gi."
  }
}

########################################
# 4. Account duoc ghi state
#
# Layer chay o account khac (vi du layer network chay o account
# network) van can ghi state vao bucket nay.
#
# Key = ten prefix trong bucket, value = account ID.
# Moi account CHI ghi duoc vao prefix cua chinh no.
########################################

variable "state_writer_accounts" {
  description = <<-EOT
    Account duoc phep ghi state, kem prefix rieng.

    Vi du:
      { network = "222222222222", security = "333333333333" }
    -> account 2222 chi ghi duoc vao s3://<bucket>/network/*

    Management account luon ghi duoc moi prefix - khong can khai o day.

    De rong neu moi layer deu chay o management account.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for _, id in var.state_writer_accounts : can(regex("^[0-9]{12}$", id))
    ])
    error_message = "Account ID phai dung 12 chu so."
  }

  validation {
    condition = alltrue([
      for k, _ in var.state_writer_accounts : can(regex("^[a-z0-9][a-z0-9-]*$", k))
    ])
    error_message = "Ten prefix chi gom chu thuong, so va dau gach ngang."
  }
}

########################################
# 5. Ghi log truy cap
########################################

variable "enable_access_logging" {
  description = <<-EOT
    Ghi log moi lan doc/ghi bucket state sang mot bucket rieng.

    State la thu co gia tri nhat trong ca ha tang - no mo ta chinh
    xac ban dang co gi va o dau. Biet ai da doc no la co ich.

    Chi phi: phi luu tru log (rat nho, va co lifecycle don sau 90 ngay).
  EOT
  type        = bool
  default     = true
}

variable "backend_profiles" {
  description = <<-EOT
    Layer -> profile AWS dung RIENG cho backend S3.

    Gan nhu moi layer khong can dong nay: chung chay o management
    account, noi dat bucket state, nen credential mac dinh doc duoc.

    Truong hop can: layer co BACKEND o mot account va RESOURCE o
    account khac. Vi du demo/network-lz-full khi duoc giu lam mang
    that - chay bang AWS_PROFILE=lz-network de resource roi vao
    account network, trong khi bucket state van o management:

      backend_profiles = {
        "demo/network-lz-full" = "default"   # profile cua management
      }

    Khong co dong nay thi terraform init bao:
      Error refreshing state: ... HeadObject ... StatusCode: 403

    Them tay vao backend.hcl cung chay, NHUNG wire-backends.sh ghi de
    file do moi lan chay - dong them tay se bien mat im lang. Khai o
    day thi no duoc sinh lai moi lan.
  EOT
  type        = map(string)
  default     = {}
}

########################################
# TEARDOWN
########################################

variable "allow_destroy" {
  description = <<-EOT
    Go moi lop bao ve PHIA AWS de destroy chay duoc.

    Layer nay: bat force_destroy cho bucket state va bucket log truy
    cap. Bucket deu bat versioning, nen KHONG co force_destroy thi
    "aws s3 rm --recursive" chi tao delete marker va destroy van dung
    lai voi BucketNotEmpty.

    force_destroy la thuoc tinh PHIA PROVIDER - doi no khong goi mot
    API nao ca. Nghia la apply gan nhu tuc thi, va SCP khong can vao
    duoc. Nhung no CHI co tac dung neu da nam trong state TRUOC khi
    destroy: phai apply mot lan rieng, roi moi destroy.

    Con mot lop nua khong bien nao go duoc: prevent_destroy. Terraform
    khong cho dung bien trong lifecycle. Dung ./unlock-destroy.sh.

    Bat MFA Delete roi thi ke ca force_destroy cung khong xoa noi
    version - chi credential ROOT kem ma MFA lam duoc, bang CLI.

    Quy trinh: xem TEARDOWN.md muc 2.
  EOT
  type        = bool
  default     = false
}
