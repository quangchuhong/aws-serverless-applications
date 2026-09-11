########################################
# BIEN CUA CALLER
#
# MO TA DAY DU nam o ../../modules/tf-pipeline/variables.tf. O day chi
# ghi mot dong, va chi ghi them khi caller nay co dieu gi RIENG.
#
# Vi sao phai khai lai: Terraform chi nhan gia tri tu tfvars cho bien cua
# CHINH layer, khong xuyen vao module. Nen moi bien muon dat tu tfvars
# phai co mot khai bao o day.
########################################

variable "region" {
  type    = string
  default = "ap-southeast-1"
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
# MAC DINH TAT
#
# Bat cai nay tao mot duong TU DONG co quyen sua SCP cua ca to chuc. SCP
# la tran quyen cho MOI account - mot thay doi sai o day khong lam gi
# "hong", no chi lam mot viec truoc day bi chan gio chay duoc. Kieu su co
# do khong co trieu chung.
########################################

variable "enable" {
  type    = bool
  default = false
}

########################################
# NGUON
########################################

variable "source_type" {
  type    = string
  default = "codecommit"

  validation {
    condition     = contains(["codecommit", "s3"], var.source_type)
    error_message = "source_type phai la codecommit hoac s3."
  }
}

variable "repository_name" {
  type    = string
  default = "diy-aws-landing-zone"
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
# STATE CUA CAC LAYER MA PIPELINE NAY APPLY
########################################

variable "state_bucket" {
  type = string
}

variable "state_lock_table" {
  type    = string
  default = ""
}

variable "layer_keys" {
  description = "Layer -> khoa state. Moi stage duoc bat phai co mot dong o day."
  type        = map(string)
}

variable "tfvars_bucket" {
  type    = string
  default = ""
}

########################################
# CONG DUYET
#
# approve_stages: TEN STAGE, khong phai ten layer. Ten hop le xem
# local.stages trong main.tf.
#
# Go sai KHONG gay loi luc chay: contains() tra ve false va cong duyet do
# khong ton tai, trong khi tfvars noi rang co. Check
# "approve_stages_la_ten_that" trong module bat viec do luc plan.
########################################

variable "approve_stages" {
  type    = list(string)
  default = []
}

variable "approval_emails" {
  description = "Dia chi nhan thu can duyet. MOI DIA CHI PHAI BAM XAC NHAN, neu khong no khong nhan gi va Terraform van bao thanh cong."
  type        = list(string)
  default     = []
}


########################################
# DRIFT VA NGUONG
########################################

variable "drift_cron" {
  type    = string
  default = "cron(0 19 * * ? *)"
}

variable "drift_emails" {
  type    = list(string)
  default = []
}

variable "drift_topic_arn" {
  type    = string
  default = ""
}

variable "expiry_blocks_pipeline" {
  description = "Khoi loosen het han co lam pipeline dung khong. false = chi bao cao, va khi do phep thi hanh THAT nam o job drift hang dem."
  type        = bool
  default     = false
}

variable "build_timeout_minutes" {
  type    = number
  default = 30
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "enable_config_rules_stage" {
  description = <<-EOT
    Bat stage cloudops-config-rules.

    CAN TRUOC: role rieng cho pipeline o ACCOUNT SECURITY. Config rule
    song o do - config-detective/aggregator-rules.tf ghi
    `provider = aws.security`.

    Hom nay o account do chi co OrganizationAccountAccessRole, tuc FULL
    ADMIN. Cap cho pipeline quyen assume vao do de sua Config rule la cap
    quyen sua moi thu trong account bao mat.
  EOT
  type        = bool
  default     = false
}

variable "config_pipeline_role_arns" {
  description = <<-EOT
    ARN role pipeline nay duoc assume sang account SECURITY va
    LOG-ARCHIVE.

    RONG la mac dinh va la dung khi chua co role rieng. DUNG dien
    OrganizationAccountAccessRole.
  EOT
  type        = list(string)
  default     = []
}
