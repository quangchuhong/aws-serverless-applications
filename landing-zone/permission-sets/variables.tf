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

variable "core_accounts" {
  description = <<-EOT
    Account HA TANG LOI - khong phai noi chay workload.

      security      Config aggregator, Security Hub admin, canh bao
      log_archive   bucket CloudTrail + Config snapshot. BANG CHUNG.
      network       TGW, Network Firewall, egress

    ---------------------------------------------------------------
    VI SAO PHAI KHAI O DAY

    Pham vi "all" suy ra tu Organizations, nen no la MOI account thanh
    vien - ke ca ba account tren. Truoc khi co bien nay, lz-server-admin
    (co scope "all", va admin_actions["compute"] chua "s3") nhan quyen
    s3:* NGAY TRONG account log archive. Khong deny nao chan:
    DenyTamperingWithGuardrails chan cloudtrail:DeleteTrail va
    config:Delete*, KHONG chan s3:DeleteObject.

    Nghia la ca doi ha tang compute xoa duoc bang chung kiem toan cua
    to chuc. Ranh gioi account van con, nhung permission set dam thang
    qua no.

    De RONG thi pham vi "workloads" bang dung "all" va lop tach nay
    khong ton tai. check "core_accounts_declared" canh bao khi do.
    ---------------------------------------------------------------
  EOT
  type = object({
    security    = optional(string, "")
    log_archive = optional(string, "")
    network     = optional(string, "")
  })
  default = {}

  validation {
    condition = alltrue([
      for id in compact([
        var.core_accounts.security,
        var.core_accounts.log_archive,
        var.core_accounts.network,
      ]) : can(regex("^[0-9]{12}$", id))
    ])
    error_message = "Account ID phai dung 12 chu so, hoac de rong."
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

  validation {
    condition = alltrue([
      for k in keys(var.passrole_prefixes) :
      contains(["workload", "analytics"], k)
    ])
    error_message = "Chi chap nhan hai khoa: workload, analytics. Khoa khac bi bo qua im lang - policy van dung default, ban tuong da doi ma khong doi."
  }

  validation {
    condition = alltrue([
      for _, p in var.passrole_prefixes : p != "" && !strcontains(p, "*")
    ])
    error_message = "Tien to phai khac rong va khong chua dau *. Tien to rong -> policy thanh role/* = PassRole moi role = mat sach tac dung chan leo thang quyen."
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

    KHOA CUA MAP LA USERNAME DANG NHAP. Dat cho de go, khong dau.

    ---------------------------------------------------------------
    SAU KHI APPLY PHAI LAM MOT BUOC THU CONG cho tung user moi:

      Identity Center console -> Users -> chon user
      -> Reset password
      -> "Send an email to the user with instructions for resetting
         the password"

    API CreateUser ma Terraform dung KHONG gui thu moi. Bo qua buoc
    nay thi user ton tai day du, co group, co quyen - ma khong bao
    gio dang nhap duoc, vi chua bao gio co password.

    Trieu chung la "khong nhan duoc email", khong phai mot loi nao.
    ---------------------------------------------------------------

    Email o day CHI dung de nhan thu dat password - KHONG can duy nhat
    toan cau. Rat khac email root account. Dung lai email ca nhan duoc,
    va plus-addressing (ban+ten@gmail.com) cho bao nhieu dia chi cung
    duoc ma van ve mot hop thu.

    groups = ten group trong local.groups (xem identity.tf). Group
    quyet dinh user thay account nao voi quyen gi. Co check block chan
    neu khai group khong ton tai.
  EOT
  type = map(object({
    given_name  = string
    family_name = string
    email       = string
    groups      = list(string)
  }))
  default = {}
}
