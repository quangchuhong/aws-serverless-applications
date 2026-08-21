variable "enable" {
  description = <<-EOT
    MAC DINH FALSE.

    False = khong tao gi. terraform plan van chay va kiem chung cu phap.

    Bat khi da co account security tooling + log archive that su ton tai,
    va da uy quyen delegated administrator ben landing-zone/organization.
  EOT
  type        = bool
  default     = false
}

variable "region" {
  description = "Region chinh. Config la per-region - moi region them vao nhan chi phi len theo so account."
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
# 1. Account
########################################

variable "security_account_id" {
  description = "Account security tooling - giu aggregator, Security Hub admin, canh bao"
  type        = string
  default     = ""
}

variable "log_archive_account_id" {
  description = "Account log archive - giu S3 nhan Config snapshot"
  type        = string
  default     = ""
}

variable "cross_account_role" {
  description = <<-EOT
    Role Terraform assume sang hai account tren.

    Account tao qua Organizations co san OrganizationAccountAccessRole.
    Account MOI TU NGOAI VAO thi KHONG co - phai tao role tuong duong
    truoc (xem doc 09 muc 5).
  EOT
  type        = string
  default     = "OrganizationAccountAccessRole"
}

variable "recorder_target_ous" {
  description = <<-EOT
    OU ID se duoc trien khai Config recorder qua StackSet.

    KHONG dua OU Sandbox / Dev vao day. Do la noi nhieu resource thay
    doi nhat -> nhieu configuration item nhat -> dat nhat, ma vi pham
    o do lai la chuyen binh thuong.

    Lay ID: terraform output ou_ids  (o layer organization)
  EOT
  type        = list(string)
  default     = []
}

########################################
# 2. Pham vi ghi - CAN GAT CHI PHI
########################################

variable "recording_frequency" {
  description = <<-EOT
    CAN GAT CHI PHI LON NHAT.

    "CONTINUOUS" - ghi mot configuration item MOI LAN resource doi.
                   Mac dinh cua AWS, va la cach dat nhat.
    "DAILY"      - ghi mot ban tom tat moi ngay.

    Dat DAILY, roi dung continuous_recording_types de dua rieng vai
    loai ve che do lien tuc.
  EOT
  type        = string
  default     = "DAILY"

  validation {
    condition     = contains(["CONTINUOUS", "DAILY"], var.recording_frequency)
    error_message = "Chi nhan CONTINUOUS hoac DAILY."
  }
}

variable "continuous_recording_types" {
  description = <<-EOT
    Loai resource van ghi lien tuc du recording_frequency = DAILY.

    Chi dua vao day nhung thu ma cham tre mot ngay la qua lau -
    thay doi ve quyen va ve port.
  EOT
  type        = list(string)
  default = [
    "AWS::EC2::SecurityGroup",
    "AWS::IAM::Role",
    "AWS::IAM::Policy",
  ]
}

variable "resource_types" {
  description = <<-EOT
    Loai resource duoc ghi. KHONG dung all_supported = true.

    Danh sach mac dinh chon DOI XUNG voi 4 SCP ben layer organization:
    SCP ngan hanh dong, Config phat hien cai da ton tai.

    Them mot loai = them configuration item = them chi phi. Chi them
    khi co rule that su kiem tra loai do.
  EOT
  type        = list(string)

  default = [
    # Doi xung voi SCP network_lock
    "AWS::EC2::InternetGateway",
    "AWS::EC2::NatGateway",
    "AWS::EC2::SecurityGroup",
    "AWS::EC2::VPC",
    "AWS::EC2::RouteTable",
    "AWS::EC2::Volume",

    # Doi xung voi SCP baseline
    "AWS::IAM::Role",
    "AWS::IAM::User",
    "AWS::IAM::Policy",
    "AWS::CloudTrail::Trail",

    # Doi xung voi SCP prod_guard
    "AWS::S3::Bucket",
    "AWS::KMS::Key",
    "AWS::RDS::DBInstance",
  ]

  validation {
    condition     = length(var.resource_types) > 0
    error_message = "Phai co it nhat mot loai resource."
  }
}

variable "aggregator_regions" {
  description = <<-EOT
    Region ma aggregator gom du lieu.

    KHONG dung all_regions = true - no gom ca region ban khong dung,
    va lam mo mat cai nhin ve chi phi.
  EOT
  type        = list(string)
  default     = ["ap-southeast-1", "us-east-1"]
}

########################################
# 3. Rule
########################################

variable "organization_rules" {
  description = <<-EOT
    Managed rule trien khai cho TOAN TO CHUC tu delegated admin.

    Dung aws_config_organization_managed_rule chu khong phai tao rule
    o tung account - mot resource, ap cho moi account.

    Key   = ten rule
    Value = source_identifier cua AWS managed rule (CHU HOA, gach duoi)

    MOI RULE LA MOT KHOAN CHI PHI. Dung bat ca conformance pack "cho
    chac" - vai chuc rule, moi rule danh gia deu tinh tien, va ban se
    khong doc het findings.

    Danh sach day du:
      aws configservice describe-config-rules  (hoac tai lieu AWS)
  EOT
  type        = map(string)

  default = {
    "s3-bucket-public-read-prohibited"         = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
    "s3-bucket-public-write-prohibited"        = "S3_BUCKET_PUBLIC_WRITE_PROHIBITED"
    "s3-bucket-server-side-encryption-enabled" = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
    "encrypted-volumes"                        = "ENCRYPTED_VOLUMES"
    "iam-root-access-key-check"                = "IAM_ROOT_ACCESS_KEY_CHECK"
    "cloud-trail-enabled"                      = "CLOUD_TRAIL_ENABLED"
    "vpc-sg-open-only-to-authorized-ports"     = "VPC_SG_OPEN_ONLY_TO_AUTHORIZED_PORTS"
    "rds-storage-encrypted"                    = "RDS_STORAGE_ENCRYPTED"
  }
}

variable "excluded_accounts" {
  description = <<-EOT
    Account KHONG ap organization rule.

    Thuong la sandbox va cac account thu nghiem - noi vi pham la
    chuyen binh thuong va bao dong chi tao nhieu.
  EOT
  type        = list(string)
  default     = []
}

########################################
# 4. Log archive
########################################

variable "enable_object_lock" {
  description = <<-EOT
    S3 Object Lock cho bucket nhan snapshot.

    CHI BAT DUOC LUC TAO BUCKET - khong bat sau duoc. Quyet dinh ngay.

    Ca ly do tach rieng account log archive la de account bi xam nhap
    KHONG XOA DUOC bang chung. Lifecycle policy khong lam duoc viec do -
    no chi chuyen storage class va het han.
  EOT
  type        = bool
  default     = true
}

variable "object_lock_retention_days" {
  description = <<-EOT
    So ngay khong ai xoa duoc object, ke ca root.

    HE QUA THUC TE hay bi bo qua: bucket KHONG XOA DUOC cho den khi
    object cuoi cung het han. Dat 90 nghia la neu muon don sach lab
    thi phai doi 90 ngay - khong co duong tat, COMPLIANCE mode khong
    co ai go duoc.

    Lab dang thu: 7 - van chung minh duoc co che, khoa chan 1 tuan.
    Moi truong that:  90 tro len, theo yeu cau tuan thu cua ban.
  EOT
  type        = number
  default     = 90

  validation {
    condition     = var.object_lock_retention_days >= 1
    error_message = "Phai it nhat 1 ngay."
  }
}

variable "snapshot_retention_days" {
  description = <<-EOT
    Sau bao nhieu ngay thi lifecycle xoa snapshot.

    PHAI LON HON object_lock_retention_days. Nho hon thi lifecycle co
    xoa object ma Object Lock cam xoa: KHONG BAO LOI, object tich lai
    mai, va ban tra tien luu tru vo thoi han cho thu tuong da duoc don.
  EOT
  type        = number
  default     = 365

  validation {
    condition     = var.snapshot_retention_days > 0
    error_message = "Phai lon hon 0."
  }
}

variable "snapshot_delivery_frequency" {
  description = <<-EOT
    Tan suat giao snapshot dinh ky vao S3.

    TwentyFour_Hours re nhat va du cho hau het nhu cau - day la ban
    chup toan canh, khong phai luong su kien.
  EOT
  type        = string
  default     = "TwentyFour_Hours"

  validation {
    condition = contains([
      "One_Hour", "Three_Hours", "Six_Hours", "Twelve_Hours", "TwentyFour_Hours"
    ], var.snapshot_delivery_frequency)
    error_message = "Gia tri khong hop le."
  }
}

########################################
# 5. Canh bao
#
# QUYET DINH KIEN TRUC: khong lam EventBridge fan-in cross-account.
#
# Config managed rule TU DAY finding vao Security Hub, va Security Hub
# da co san gom cross-account + cross-region qua delegated admin.
# Lam them mot duong EventBridge rieng la lam lai viec do, va phai
# trien khai rule + IAM role o MOI account x MOI region.
#
# Nen o day chi co MOT rule EventBridge, dat NGAY TAI security account,
# doc finding da duoc Security Hub gom san.
########################################

variable "alert_emails" {
  description = "Email nhan canh bao. Moi email phai XAC NHAN qua link SNS gui toi."
  type        = list(string)
  default     = []
}

variable "alert_severities" {
  description = <<-EOT
    Muc do nghiem trong duoc bao.

    Bao het moi muc = khong ai doc nua. Bat dau tu CRITICAL + HIGH.
  EOT
  type        = list(string)
  default     = ["CRITICAL", "HIGH"]
}

variable "enable_slack" {
  description = <<-EOT
    Bat Lambda day canh bao sang Slack.

    Can slack_webhook_secret_name tro toi mot secret DA TON TAI trong
    Secrets Manager cua account security. KHONG dat webhook URL vao
    bien Terraform - no se nam trong state o dang ro.
  EOT
  type        = bool
  default     = false
}

variable "slack_webhook_secret_name" {
  description = "Ten secret trong Secrets Manager chua webhook URL"
  type        = string
  default     = "lz/slack/security-alerts"
}
