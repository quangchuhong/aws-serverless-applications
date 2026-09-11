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
# approve_stages: TEN STAGE, khong phai ten layer. Ten hop le la
# sec-ou / sec-scp / sec-tagging - xem local.stages trong main.tf.
#
# Go sai KHONG gay loi luc chay: contains() tra ve false va cong duyet do
# khong ton tai, trong khi tfvars noi rang co. Check
# "approve_stages_la_ten_that" trong module bat viec do luc plan.
########################################

variable "approve_stages" {
  type    = list(string)
  default = ["sec-scp"]
}

variable "approval_emails" {
  description = "Dia chi nhan thu can duyet. MOI DIA CHI PHAI BAM XAC NHAN, neu khong no khong nhan gi va Terraform van bao thanh cong."
  type        = list(string)
  default     = []
}

########################################
# HAI STAGE CUNG LAYER organization
#
# SCP, OU va tag policy nam cung MOT state. Tach o day la tach PHAM VI
# (bang -target va bang PHAM_VI trong ops-gate/gate.py), khong tach state.
########################################

variable "enable_ou_stage" {
  description = <<-EOT
    Bat stage sec-ou: cay OU, cung layer organization.

    GIU NGUYEN CODE TF CUA OU - khong catalog hoa, khong tach state.

    PHAI BIET TRUOC KHI BAT: doi TEN mot OU se bi chan, va chan o stage
    sec-scp chu khong o day. Khoa cua
    aws_organizations_policy_attachment.scp la "<policy>|<TEN OU>", nen
    doi ten OU doi KHOA trong Terraform du khong doi id o AWS - Terraform
    thay destroy + create, va FAIL_ON_DESTROY tu choi.

    Do la ly do stage sec-ou dat TRUOC sec-scp: de viec chan xay ra trong
    CUNG mot luot, co nguoi doc. THEM mot OU moi thi khong vuong.

    BIEN NAY CUNG MO QUYEN IAM: local.quyen_dich_vu trong main.tf them
    organizations:*OrganizationalUnit khi bien nay true, va
    local.tu_choi_dich_vu bo chung khoi Deny. Phai ca hai - Deny THANG
    Allow, nen mo Allow ma quen bo khoi Deny thi khong co gi doi.
  EOT
  type        = bool
  default     = false
}

variable "enable_tagging_stage" {
  description = <<-EOT
    Bat stage sec-tagging: tag policy, cung layer organization.

    MAC DINH TAT vi mot ly do do duoc: tag_policy.enabled = false o layer
    organization, nen aws_organizations_policy.tag dang co 0 instance.
    Mot stage cho resource khong ton tai se ra "KHONG CO THAY DOI" mai
    mai - luon xanh ma khong kiem gi.

      cd ../organization && terraform output tag_policy
  EOT
  type        = bool
  default     = false
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
