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

variable "drift_emails" {
  description = <<-EOT
    Dia chi nhan bao drift. Khai o day thi layer nay TU TAO topic o
    account management.

    NEN DUNG CACH NAY thay vi drift_topic_arn tro sang account khac.
    Publish lien account can CA HAI phia cho phep: IAM cua role o day,
    VA resource policy cua topic ben kia. Topic cua config-detective
    chi cho Principal = events.amazonaws.com, nen mot ARN tro sang do
    se bi tu choi - va buoc drift se in "khong bao duoc ve SNS" moi
    dem ma khong ai doc.

    Moi dia chi nhan mot thu tu SNS va PHAI BAM XAC NHAN. Truoc do
    subscription o PendingConfirmation va khong nhan gi - Terraform van
    bao tao thanh cong.
  EOT
  type        = list(string)
  default     = []
}

variable "drift_topic_arn" {
  description = <<-EOT
    Dung mot topic CO SAN thay vi tao moi. Loai tru voi drift_emails.

    Neu topic nam o ACCOUNT KHAC thi phai tu them statement cho phep
    role cua layer nay publish - Terraform o day khong sua duoc
    resource policy cua topic o account khac.

    Lay ARN topic cua config-detective (o account security):
      cd ../config-detective && terraform output alert_topic

    LUU Y ten: topic do la "<project>-security-findings", va output ten
    la `alert_topic`. Dung doan ten - mot ARN go tay trong nhu that se
    duoc dung nhu that, va loi duy nhat la mot dong canh bao trong log
    luc 2 gio sang.
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

########################################
# BAT/TAT TUNG STAGE
#
# Mac dinh TAT het tru A-scp. Mot stage tro vao layer chua ton tai, hoac
# vao layer co state RONG, se dung o chot chan "state RONG" cua
# buildspec - va thong bao o do noi ve SAI KHOA STATE chu khong noi rang
# layer chua duoc dung. Doc log do se dan nguoi ta di sua backend, dung
# cho khong hong.
#
# Nen ba bien duoi day khong phai co cho sang trong: chung la cach noi
# "layer nay da ton tai va da apply mot lan".
########################################




########################################
# STAGE Expiry
########################################

variable "expiry_blocks_pipeline" {
  description = <<-EOT
    Mot khoi `loosen` HET HAN co lam pipeline dung hay khong.

    false (mac dinh) = stage Expiry chi BAO CAO. Dung voi chu "bao cao"
    trong thiet ke, va dung voi mo ta cua lint.sh: che do --expiry sinh
    ra cho mot job chay theo lich, khong cho duong apply.

    NHUNG PHAI BIET DIEU NAY: mot stage khong bao gio that bai la mot
    stage khong ai doc ket qua. Neu de false thi phep thi hanh THAT phai
    nam o job drift hang dem - va phai co nguoi doc bao dong cua no.
    Khong co ca hai thi moi khoi loosen deu song vinh vien.

    true = het han thi dung pipeline. Chon cai nay khi khong chac co ai
    doc bao cao hang dem.
  EOT
  type        = bool
  default     = false
}

########################################
# HAI STAGE CUNG LAYER organization
#
# SCP, OU va tag policy nam cung mot layer va CUNG MOT STATE. Chung
# khong tach ra thanh ba layer - tach state la them hai lan init, hai
# khoa, va hai cho de lech. Tach o day la tach PHAM VI, bang -target va
# bang bang PHAM_VI trong ops-gate/gate.py.
########################################

variable "enable_ou_stage" {
  description = <<-EOT
    Bat stage A-ou: cay OU, cung layer organization.

    GIU NGUYEN CODE TF CUA OU - khong catalog hoa, khong tach state.
    Stage nay chi -target vao resource da co.

    PHAI BIET TRUOC KHI BAT: doi TEN mot OU se bi chan, va chan o stage
    B-scp chu khong o day.

    Khoa cua aws_organizations_policy_attachment.scp la
    "<policy>|<TEN OU>". Doi ten OU khong doi id cua no o AWS, nhung doi
    khoa trong Terraform - nen Terraform thay mot destroy + create tren
    cung mot OU id. Khong doi gi o AWS, va van la destroy, nen
    FAIL_ON_DESTROY tu choi.

    Do la ly do stage A-ou dat TRUOC B-scp: de viec chan xay ra trong
    CUNG mot luot chay, co nguoi doc. Neu SCP chay truoc thi OU doi xong
    va khong co gi doi chieu lai attachment cho toi luot sau.

    THEM mot OU moi thi khong vuong dieu nay.
  EOT
  type        = bool
  default     = false
}

variable "enable_tagging_stage" {
  description = <<-EOT
    Bat stage C-tagging: tag policy, cung layer organization.

    MAC DINH TAT vi mot ly do do duoc, khong phai vi than trong:
    tag_policy.enabled = false o layer organization, nen
    aws_organizations_policy.tag dang co 0 instance.

    Mot stage cho resource khong ton tai se ra "KHONG CO THAY DOI" mai
    mai - va mot stage luon xanh ma khong kiem gi la kieu hong im lang.

    Kiem truoc khi bat:

      cd ../organization && terraform output tag_policy
      # "enabled" = true  thi bat duoc
  EOT
  type        = bool
  default     = false
}
