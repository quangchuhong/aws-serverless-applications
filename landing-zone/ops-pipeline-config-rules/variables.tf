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

########################################
# RULE COMMIT RIENG CUA PIPELINE NAY
#
# true  = moi commit vao nhanh deu lam pipeline nay chay (khong loc duoc
#         theo duong dan - su kien CodeCommit khong mang danh sach file)
# false = chi chay khi landing-zone/trigger-filter goi ten no
#
# THU TU: bat trigger-filter TRUOC, roi moi dat false o day. Nguoc lai
# thi giua hai lan apply khong co gi kich hoat pipeline nao.
#
# Mo ta day du o ../../modules/tf-pipeline/variables.tf.
########################################
variable "tu_kich_hoat" {
  type    = bool
  default = true
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

  # [""] khong phai []: length la 1, va Terraform nhan vi no DUNG kieu
  # list(string). Module cung co validation nay - khai lai o day de
  # thong bao goi ten bien cua LAYER, tuc dung ten ma nguoi sua
  # terraform.tfvars dang doc.
  validation {
    condition     = alltrue([for e in var.approval_emails : can(regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", e))])
    error_message = "approval_emails co phan tu khong phai dia chi email. De trong thi viet [] - [\"\"] la danh sach CO MOT phan tu rong."
  }
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

  # [""] khong phai []: length la 1, va Terraform nhan vi no DUNG kieu
  # list(string). Module cung co validation nay - khai lai o day de
  # thong bao goi ten bien cua LAYER, tuc dung ten ma nguoi sua
  # terraform.tfvars dang doc.
  validation {
    condition     = alltrue([for e in var.drift_emails : can(regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", e))])
    error_message = "drift_emails co phan tu khong phai dia chi email. De trong thi viet [] - [\"\"] la danh sach CO MOT phan tu rong."
  }
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

variable "config_verify_role_arn" {
  description = <<-EOT
    ARN role buoc Verify assume sang de DOC organization config rule.

    RONG thi buoc Verify van chay, nhung doc bang danh tinh CodeBuild o
    account management. Neu management khong thay rule cua delegated admin
    thi ket qua la "0 rule", va script bao LOI chu khong bao mau xanh -
    doc duoc va rong khong duoc coi la "khong co gi sai".

    PHAI la mot trong cac ARN da khai o config_pipeline_role_arns, neu
    khong thi statement sts:AssumeRole khong phu no va buoc Verify do voi
    AccessDenied. Co check "arn_verify_nam_trong_danh_sach_assume" canh.

    CHI DOC: script chi goi describe-organization-config-rules va
    get-organization-config-rule-detailed-status.
  EOT
  type        = string
  default     = ""
}
