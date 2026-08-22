variable "enable" {
  description = <<-EOT
    Bat/tat ca layer. Mac dinh FALSE.

    false -> terraform plan ra 0 resource, khong cham vao gi.

    Bat khi da co account log archive va da uy quyen service access
    cho cloudtrail.amazonaws.com (layer organization lam san).
  EOT
  type        = bool
  default     = false
}

variable "region" {
  description = <<-EOT
    Region tao trail va bucket.

    Trail la MULTI-REGION (is_multi_region_trail) nen no ghi su kien
    o MOI region bat ke dat o dau. Region nay chi quyet dinh noi dat
    resource, khong gioi han pham vi ghi.
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
# 1. Account
########################################

variable "log_archive_account_id" {
  description = <<-EOT
    Account nhan log. PHAI khac management account.

    Ca ly do tach account nay: account bi xam nhap khong duoc xoa
    bang chung cua chinh no. Dat bucket ngay trong account bi tan
    cong thi lop bao ve nay mat y nghia.
  EOT
  type        = string

  validation {
    condition     = var.log_archive_account_id == "" || can(regex("^[0-9]{12}$", var.log_archive_account_id))
    error_message = "Phai la 12 chu so hoac de rong."
  }
}

variable "cross_account_role" {
  description = "Role assume sang account log archive"
  type        = string
  default     = "OrganizationAccountAccessRole"
}

########################################
# 2. Pham vi ghi
########################################

variable "data_events" {
  description = <<-EOT
    Ghi data event (S3 GetObject/PutObject, Lambda Invoke...).

    ===============================================================
    MAC DINH FALSE, VA DAY LA CAN GAT CHI PHI LON NHAT.

    Management event: ban sao dau tien MIEN PHI cho moi account.
    Data event:       TINH TIEN THEO TUNG SU KIEN.

    Mot bucket S3 co luu luong binh thuong sinh hang trieu su kien
    moi thang. Bat "cho chac" o pham vi to chuc la cach nhanh nhat
    de bien mot layer mien phi thanh khoan lon nhat trong hoa don.
    ===============================================================

    Bat khi CAN, va bat CO PHAM VI - chi bucket chua du lieu nhay
    cam, khong phai tat ca. Chinh sua resource block trong main.tf
    khi do, dung bat toan bo.
  EOT
  type        = bool
  default     = false
}

variable "enable_log_file_validation" {
  description = <<-EOT
    Ghi kem file digest de phat hien log bi sua hoac bi xoa.

    Nen BAT. Khong co no thi log van co the bi sua ma khong ai biet,
    va ca chuoi bang chung mat gia tri truoc mot cuoc dieu tra.

    Chi phi: khong dang ke, digest rat nho.
  EOT
  type        = bool
  default     = true
}

########################################
# 3. Luu tru
########################################

variable "log_retention_days" {
  description = <<-EOT
    Sau bao nhieu ngay thi lifecycle xoa log.

    PHAI lon hon moc chuyen storage class (30 cho STANDARD_IA,
    90 cho GLACIER_IR) - nho hon thi transition tu dong bi bo qua,
    va S3 tu choi ca cau hinh:

      InvalidArgument: 'Days' in the Expiration action must be
      greater than 'Days' in the Transition action

    365 la muc thuong dung. Yeu cau tuan thu co the doi dai hon.
  EOT
  type        = number
  default     = 365

  validation {
    condition     = var.log_retention_days > 0
    error_message = "Phai lon hon 0."
  }
}

variable "enable_object_lock" {
  description = <<-EOT
    S3 Object Lock cho bucket nhan log.

    CHI BAT DUOC LUC TAO BUCKET. Khong bat sau duoc.

    ===============================================================
    CHUA KIEM CHUNG VOI CLOUDTRAIL - MAC DINH FALSE.

    Layer config-detective da vap dung cho nay: AWS Config KHONG
    ghi duoc vao bucket co Object Lock, vi S3 doi header Content-MD5
    tren moi PutObject vao bucket khoa, va Config khong gui.

    CloudTrail CO gui Content-MD5 hay khong thi TOI CHUA DO. Nen mac
    dinh de false thay vi doan - bat nham la phai xoa bucket lam lai,
    ma prevent_destroy dang chan xoa.

    MUON DUNG THI DO TRUOC, mat 2 phut va $0:

      B=test-lock-$RANDOM
      aws s3api create-bucket --bucket $B --region <region> \
        --create-bucket-configuration LocationConstraint=<region> \
        --object-lock-enabled-for-bucket --profile <log-archive>
      # gan bucket policy CloudTrail cho $B, roi:
      aws cloudtrail create-trail --name test-lock --s3-bucket-name $B
      aws cloudtrail start-logging --name test-lock
      # doi ~15 phut roi xem co file nao vao bucket khong
      aws s3 ls s3://$B --recursive
      # don: delete-trail, rb --force

    Ra file = dung duoc. Rong = giong Config, khong dung duoc.
    ===============================================================

    Khong co Object Lock thi van con: bucket o account RIENG,
    versioning, public access block, log file validation, va
    baseline SCP chan cloudtrail:StopLogging va DeleteTrail.
  EOT
  type        = bool
  default     = false
}

variable "object_lock_retention_days" {
  description = "So ngay khong ai xoa duoc object. Chi co tac dung khi enable_object_lock = true."
  type        = number
  default     = 7

  validation {
    condition     = var.object_lock_retention_days >= 1
    error_message = "Phai it nhat 1 ngay."
  }
}
