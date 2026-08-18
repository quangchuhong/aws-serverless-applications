variable "region" {
  description = <<-EOT
    Region "home" cua Control Tower.

    CHON MOT LAN, KHONG DOI DUOC. Doi home region nghia la
    decommission roi dung lai tu dau.
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

########################################
# CONG TAC CHINH
########################################

variable "enable_landing_zone" {
  description = <<-EOT
    MAC DINH FALSE.

    False = khong tao gi ca. terraform plan van chay va kiem chung
            duoc cu phap - dung de doi chieu voi ban DIY.

    True  = dung Control Tower that. Doc ky ba canh bao o dau
            versions.tf truoc khi doi.
  EOT
  type        = bool
  default     = false
}

variable "create_core_accounts" {
  description = <<-EOT
    Tao hai account bat buoc cua Control Tower: Log Archive va Audit.

    aws_controltower_landing_zone doi ACCOUNT ID CO SAN trong manifest
    - no khong tu tao hai account nay. Nen phai tao truoc.

    Da co san (vi du CT tung duoc bat roi go) -> dat false va dien
    log_archive_account_id / audit_account_id.
  EOT
  type        = bool
  default     = true
}

variable "log_archive_account_id" {
  description = "Chi dien khi create_core_accounts = false"
  type        = string
  default     = ""
}

variable "audit_account_id" {
  description = "Chi dien khi create_core_accounts = false"
  type        = string
  default     = ""
}

variable "core_account_emails" {
  description = <<-EOT
    Email cho hai account loi. PHAI duy nhat toan cau va PHAI la
    email that - AWS gui thu xac nhan va do la duong khoi phuc root
    duy nhat cua account do.

    Dung plus-addressing neu it email:
      ban+lz-logarchive-01@gmail.com
      ban+lz-audit-01@gmail.com

    Them hau to phien ban (-01) ngay tu dau: email da dung cho mot
    AWS account thi KHONG tai su dung duoc, ke ca sau khi dong
    account do.
  EOT
  type = object({
    log_archive = string
    audit       = string
  })
  default = {
    log_archive = ""
    audit       = ""
  }
}

########################################
# Manifest
########################################

variable "landing_zone_version" {
  description = <<-EOT
    Phien ban landing zone cua Control Tower.

    Day la thu duoc "upgrade" khi noi den nang cap Control Tower:
    doi so nay roi apply. Sau khi nang, cac account thuong phai
    RE-ENROLL - buoc do khong tu dong.

    Xem phien ban hien co: console Control Tower -> Landing zone
    settings, hoac
      aws controltower get-landing-zone --landing-zone-identifier <arn>
  EOT
  type        = string
  default     = "3.3"
}

variable "governed_regions" {
  description = <<-EOT
    Region duoc Control Tower quan tri.

    DAY LA BIEN QUYET DINH CHI PHI. Config chay o MOI account x MOI
    region trong danh sach. Them mot region = nhan chi phi Config
    len theo so account.

    Giu it nhat co the.
  EOT
  type        = list(string)
  default     = ["ap-southeast-1"]

  validation {
    condition     = length(var.governed_regions) > 0
    error_message = "Phai co it nhat mot region."
  }
}

variable "security_ou_name" {
  description = "Ten OU chua hai account loi. CT tao san."
  type        = string
  default     = "Security"
}

variable "sandbox_ou_name" {
  description = "Ten OU sandbox. CT tao san."
  type        = string
  default     = "Sandbox"
}

variable "log_retention_days" {
  description = <<-EOT
    Giu log tap trung bao nhieu ngay.

    Yeu to chi phi thu hai sau Config. Mac dinh cua CT la 365 ngay
    cho logging bucket - voi lab thi qua dai.
  EOT
  type        = number
  default     = 90
}

variable "access_log_retention_days" {
  type    = number
  default = 90
}

variable "enable_access_management" {
  description = <<-EOT
    true = Control Tower TU BAT IAM Identity Center va tao bo
           permission set rieng (AWSAdministratorAccess, ...).

    LUU Y VOI REPO NAY: 17 permission set o landing-zone/permission-sets
    van dung duoc - CT khong cam ban tao them. Nhung se co HAI BO
    permission set song song, phai ro ai dung bo nao.

    Da tu quan Identity Center bang Terraform roi thi cannhac dat
    false de tranh trung lap.
  EOT
  type        = bool
  default     = true
}

########################################
# Controls (guardrails)
########################################

variable "controls" {
  description = <<-EOT
    Control can bat, theo tung OU.

    Key   = ten OU (phai la OU DA DUOC CT quan tri)
    Value = danh sach control identifier (phan duoi cung cua ARN)

    QUAN TRONG - PHAI TU KIEM CHUNG DANH SACH NAY.
    Control identifier thay doi theo thoi gian va theo phien ban
    landing zone. Liet ke cai co that trong moi truong cua ban:

      aws controltower list-controls --region <home-region>

    hoac xem trong console Control Tower -> Controls.

    Dien identifier khong ton tai = apply loi ValidationException.

    De RONG de bat controls bang tay tren console truoc, roi moi
    dua vao code.
  EOT
  type        = map(list(string))
  default     = {}

  # Vi du - KIEM CHUNG TRUOC KHI DUNG:
  #
  # controls = {
  #   "Workloads" = [
  #     "AWS-GR_RESTRICT_ROOT_USER",
  #     "AWS-GR_RESTRICT_ROOT_USER_ACCESS_KEYS",
  #     "AWS-GR_ENCRYPTED_VOLUMES",
  #   ]
  #   "Workloads/Production" = [
  #     "AWS-GR_DISALLOW_VPC_INTERNET_ACCESS",
  #     "AWS-GR_RESTRICTED_COMMON_PORTS",
  #   ]
  # }
}

variable "control_target_ou_arns" {
  description = <<-EOT
    Ten OU -> ARN cua OU do.

    Vi sao phai khai tay: aws_controltower_control can ARN cua OU,
    nhung OU do CONTROL TOWER tao ra chu khong phai Terraform - nen
    khong tham chieu duoc bang resource.

    Lay ARN:
      aws organizations list-organizational-units-for-parent \
        --parent-id <root-id> --query 'OrganizationalUnits[].[Name,Arn]'
  EOT
  type        = map(string)
  default     = {}
}
