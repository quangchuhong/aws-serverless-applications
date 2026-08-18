variable "region" {
  description = <<-EOT
    Region dat instance IAM Identity Center. KHONG phai region workload.

    Tim bang: aws sso-admin list-instances
  EOT
  type        = string
  default     = "ap-southeast-1"
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

variable "management_account_id" {
  description = "Account ID cua management account (noi chua Organizations + billing)"
  type        = string
}

########################################
# 1. Ban do account theo pham vi
#
# Cot \"AWS Account\" trong bang thiet ke co 5 gia tri:
#   All / Management / Data Analytics / Non-Production / Production
#
# HAN CHE PHAI BIET: Identity Center KHONG gan assignment cho OU.
# target_type chi nhan AWS_ACCOUNT. Phai liet ke tung account.
#
# Pham vi \"all\" duoc suy ra tu Organizations (xem organizations.tf).
# Bon pham vi con lai khai bao o day.
#
# HE QUA VAN HANH: tao account moi trong OU nao thi phai them vao
# day va chay lai apply, neu khong khong ai vao duoc account do.
# Gan buoc nay vao account vending (doc 09).
########################################

variable "accounts_by_scope" {
  description = <<-EOT
    Danh sach account ID theo tung pham vi.

    Khong can khai \"all\" - pham vi do suy ra tu Organizations.
    Account nao khong thuoc pham vi nao thi chi nhan cac set \"all\".
  EOT
  type        = map(list(string))

  default = {
    analytics = []
    nonprod   = []
    prod      = []
  }

  validation {
    condition = alltrue([
      for k in keys(var.accounts_by_scope) :
      contains(["analytics", "nonprod", "prod"], k)
    ])
    error_message = "Chi chap nhan cac khoa: analytics, nonprod, prod."
  }

  validation {
    condition = alltrue(flatten([
      for _, ids in var.accounts_by_scope : [
        for id in ids : can(regex("^[0-9]{12}$", id))
      ]
    ]))
    error_message = "Account ID phai dung 12 chu so."
  }
}

variable "exclude_management_from_all" {
  description = <<-EOT
    Loai management account khoi pham vi \"all\".

    Nen de true: management account phai \"sach\", va SCP KHONG ap dung
    cho no - moi quyen cap o day la quyen that khong co tran chan.
    Chi platform admin nen vao, qua lz-account-admin gan rieng.
  EOT
  type        = bool
  default     = true
}

########################################
# 2. Chan duong leo thang quyen
########################################

variable "passrole_prefixes" {
  description = <<-EOT
    Tien to ten IAM role ma cac set admin duoc phep PassRole.

    VI SAO CAN: Lambda / CloudFormation / SageMaker / EMR / Glue deu
    chay bang role duoc pass vao. PassRole khong gioi han = tao mot
    Lambda gan role admin roi invoke = chay code voi quyen admin.

    Quy uoc: role nao workload duoc nhan thi dat tien to tuong ung.
    Role admin / network / security KHONG mang tien to nay -> khong
    pass duoc.

    Hai khoa:
      workload  - dung cho lz-server-admin, lz-db-admin, lz-app-admin
      analytics - dung cho lz-analytics-admin
  EOT
  type        = map(string)

  default = {
    workload  = "lz-workload-"
    analytics = "lz-analytics-"
  }
}

variable "permission_boundary_name" {
  description = <<-EOT
    Ten IAM policy dung lam permissions boundary.

    Policy nay phai TON TAI TRONG MOI ACCOUNT - trien khai bang
    StackSet (xem doc 06 muc 12). Layer nay chi tham chieu ten.

    De rong = tat rang buoc boundary cho lz-security-admin, khi do
    lz-security-admin TUONG DUONG lz-account-admin (IAM full quyen
    = tu tao role admin roi assume). Xem doc 19 muc 3.2.
  EOT
  type        = string
  default     = "lz-boundary"
}

variable "enforce_security_admin_boundary" {
  description = <<-EOT
    Bat = lz-security-admin chi tao duoc role/user co gan boundary.

    Chi bat SAU KHI policy boundary da duoc StackSet day xuong moi
    account. Bat truoc do se lam security-admin khong tao duoc gi.
  EOT
  type        = bool
  default     = false
}

########################################
# 3. Set operator co duoc doc du lieu khong
########################################

variable "operator_can_read_data" {
  description = <<-EOT
    Mac dinh FALSE - day la khac biet quan trong nhat cua bang nay
    so voi viec dung thang AWS ReadOnlyAccess.

    ReadOnlyAccess bao gom ca Get* tren mat du lieu:
    s3:GetObject, dynamodb:GetItem/Query/Scan, secretsmanager:GetSecretValue,
    ssm:GetParameter, kms:Decrypt. Gan cho auditor o TAT CA account
    nghia la cap quyen doc toan bo du lieu production.

    False -> them mot statement Deny chan dung nhung action do,
    van giu nguyen quyen doc CAU HINH.

    LUU Y: log KHONG nam trong danh sach chan (app team can doc log
    o prod). Neu log cua ban co chua du lieu nhay cam thi phai xu ly
    o tang ghi log, khong xu ly duoc o day.
  EOT
  type        = bool
  default     = false
}

########################################
# 4. User trong Identity Center directory
#
# Chi dung khi identity source la Identity Center directory
# (khong co AD, khong co external IdP) - dung truong hop AWS-only.
#
# Neu dung SCIM tu Entra/Okta/AD: de RONG bien nay va doi
# manage_groups = false. Luc do SCIM lam chu user/group, Terraform
# chi duoc DOC (xem doc 08).
########################################

variable "manage_groups" {
  description = "Terraform lam chu group. Dat false khi dung SCIM tu IdP ngoai."
  type        = bool
  default     = true
}

variable "users" {
  description = <<-EOT
    User tao trong Identity Center directory.

    Email o day CHI dung de nhan thu dat password - KHONG can duy nhat
    toan cau. Rat khac email root account. Dung lai email ca nhan duoc.

    groups = ten group trong local.groups (xem identity.tf).
  EOT
  type = map(object({
    given_name  = string
    family_name = string
    email       = string
    groups      = list(string)
  }))
  default = {}
}
