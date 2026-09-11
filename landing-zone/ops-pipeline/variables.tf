########################################
# BIEN
########################################

variable "enable" {
  description = <<-EOT
    MAC DINH TAT.

    Bat cai nay tao mot duong TU DONG co quyen sua SCP cua ca to chuc.
    SCP la tran quyen cho moi account - mot thay doi sai o day khong
    lam gi "hong", no chi lam mot viec truoc day bi chan gio chay duoc.

    Doc README truoc, nhat la muc "Khong co cong duyet".
  EOT
  type        = bool
  default     = false
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project" {
  description = "Tien to ten. Pipeline se ten <project>-ops."
  type        = string
}

variable "cost_center" {
  type = string
}

variable "owner" {
  type = string
}

########################################
# NGUON
########################################

variable "source_type" {
  description = <<-EOT
    codecommit hoac s3.

    Repo GitHub KHONG kich hoat pipeline. Hai remote la hai ban sao -
    phai day ca hai:
      git push codecommit HEAD:main
  EOT
  type        = string
  default     = "codecommit"

  validation {
    condition     = contains(["codecommit", "s3"], var.source_type)
    error_message = "source_type phai la codecommit hoac s3."
  }
}

variable "repository_name" {
  description = <<-EOT
    Repo phai chua CA BO landing-zone/, khong chi layer nay: buildspec
    `cd landing-zone/organization`, nen mot repo chi co code pipeline se
    hong ngay o lenh cd dau tien.
  EOT
  type        = string
  default     = ""
}

variable "branch_name" {
  type    = string
  default = "main"
}

variable "source_bucket" {
  type    = string
  default = ""
}

variable "source_object_key" {
  type    = string
  default = ""
}

########################################
# STATE
########################################

variable "state_bucket" {
  description = <<-EOT
    Bucket chua state cua cac layer ops.

      cd ../tf-backend && terraform output bucket
  EOT
  type        = string
}

variable "state_lock_table" {
  description = <<-EOT
    Bang DynamoDB khoa state. De rong = khong khoa.

    De rong tren mot pipeline TU DONG la mot lua chon te: hai lan chay
    chong nhau se ghi len state cua nhau, va khong co gi bao.
  EOT
  type        = string
  default     = ""
}

variable "layer_keys" {
  description = <<-EOT
    Duong dan layer -> khoa state. PHAI khop chinh xac.

    Sai khoa thi Terraform mo mot state RONG: plan doi tao lai toan bo,
    va buildspec se dung lai o chot chan "state RONG" - nhung chi khi
    FIRST_APPLY khong bang yes.

      cd ../tf-backend && terraform output layers
  EOT
  type        = map(string)

  default = {
    "landing-zone/organization" = "organization/terraform.tfstate"
  }
}

########################################
# KHO tfvars
########################################

variable "tfvars_bucket" {
  description = <<-EOT
    Bucket chua terraform.tfvars cua cac layer. DUNG CHUNG voi
    vending-pipeline - co y.

    Vi sao khong tao kho rieng: hai kho la hai cho phai day file, va
    mot kho cu la mot ban plan SAI ma khong co loi nao. Mot kho, mot
    script (push-tfvars.sh), mot cho de nham.

      cd ../vending-pipeline && terraform output -raw tfvars_bucket

    Khoa co dang: tfvars/<duong dan layer>/terraform.tfvars
  EOT
  type        = string

  validation {
    condition     = var.tfvars_bucket != ""
    error_message = "tfvars_bucket bat buoc. Lay: cd ../vending-pipeline && terraform output -raw tfvars_bucket"
  }
}

########################################
# PHAT HIEN DRIFT
########################################

variable "drift_cron" {
  description = <<-EOT
    Lich chay buoc phat hien drift, dang cron cua EventBridge (UTC).

    Mac dinh 19:00 UTC = 2 gio sang gio Viet Nam - sau gio lam, truoc
    gio lam ngay hom sau, nen ket qua co nguoi doc vao buoi sang.

    Buoc nay CHI `terraform plan -lock=false`. Khong bao gio apply, va
    -lock=false de no khong bao gio chan mot lan apply that.
  EOT
  type        = string
  default     = "cron(0 19 * * ? *)"
}

variable "drift_topic_arn" {
  description = <<-EOT
    SNS topic nhan bao khi phat hien drift. De rong = khong ai duoc
    bao, va buoc drift chi con la mot dong log luc 2 gio sang.

    Dung duoc topic cua layer khac:
      cd ../config-detective && terraform output -raw alarm_topic_arn
  EOT
  type        = string
  default     = ""
}

########################################
# NGUONG
########################################

variable "build_timeout_minutes" {
  description = <<-EOT
    Layer organization apply nhanh (chi SCP), nhung `plan` refresh CA
    state - gom cay OU va tag policy - nen van mat vai phut o to chuc
    lon.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.build_timeout_minutes >= 5 && var.build_timeout_minutes <= 480
    error_message = "build_timeout_minutes trong khoang 5..480."
  }
}

variable "log_retention_days" {
  type    = number
  default = 90
}
