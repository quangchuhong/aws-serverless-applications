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

########################################
# HAI STAGE, HAI MUC RUI RO
#
# Tach bang -target trong cung mot layer - xem main.tf.
########################################

variable "enable_network_stage" {
  description = <<-EOT
    Bat stage cloudops-network (DNS, endpoint, route, load balancer, alarm).

    HAI DIEU KIEN:

      1. State cua network/ops KHONG duoc rong. Layer cha tung bi xoa;
         state rong nghia la buildspec dung lai (chot chan state rong),
         chu khong phai pipeline chay tren mot to chuc trong.
      2. network_deploy_role_arn phai duoc khai, va phai nam trong
         network_pipeline_role_arns.

    Diem 2 truoc day KHONG lam duoc: network/ops/versions.tf chi co
    `profile`, ma CodeBuild khong co profile nao. Gio layer da co
    `dynamic "assume_role"` (sao chep tu layer cha, mau da chay that
    trong CodeBuild), nen dieu kien nay giai duoc.
  EOT
  type        = bool
  default     = false
}

variable "enable_firewall_stage" {
  description = <<-EOT
    Bat stage cloudops-firewall (nhom luat tuong lua, ingress rule).

    Cung hai dieu kien voi enable_network_stage.

    Stage nay NEN nam trong approve_stages: TAO mot ingress rule la mo
    mot cua, va viec do khong co trieu chung nao.
  EOT
  type        = bool
  default     = false
}

variable "network_pipeline_role_arns" {
  description = <<-EOT
    ARN role ma pipeline nay duoc assume sang account NETWORK.

    RONG la hop le va la mac dinh: khi chua co role rieng thi khong nen
    cap quyen assume vao dau ca. Mot danh sach rong lam statement
    AssumeVaoAccountNetwork co Resource rong, va IAM tu choi ca policy -
    do la ly do phai giu stage TAT khi chua co role.

    ------------------------------------------------------------------
    KHUYEN NGHI GOC: dung dien OrganizationAccountAccessRole vao day -
    do la full admin trong account network, va pipeline nay chi can sua
    DNS record voi rule group.

    QUYET DINH HIEN TAI khac khuyen nghi do, va la co y: dung
    OrganizationAccountAccessRole TRUOC de cac pipeline chay on, roi thu
    hep sau. Ghi o day de lan sau khong ai doc dong tren roi tuong day
    la mot cho bo sot.

    Cach thu hep khi den luc KHONG phai la doi role, ma la them mot
    SESSION POLICY vao khoi assume_role cua provider - xem chu thich
    khoi tu_choi_dich_vu trong main.tf.
  EOT
  type        = list(string)
  default     = []
}

########################################
# ROLE PROVIDER CUA LAYER SE ASSUME
#
# Phai la MOT phan tu cua network_pipeline_role_arns o tren: danh sach do
# la thu role CodeBuild duoc phep assume, con dong nay la thu no THUC SU
# assume. Lech nhau thi CodeBuild bi AccessDenied, va thong bao cua STS
# khong nhac gi toi bien nao.
#
# Check "role_assume_nam_trong_danh_sach" ben duoi bat viec do luc apply.
########################################
variable "network_deploy_role_arn" {
  type    = string
  default = ""
}
