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

    ===============================================================
    BIEN NAY RANG BUOC VOI recorder_target_ous, VA KHONG CO GI TU
    DONG NOI CHUNG LAI.

    Organization rule day xuong MOI account thanh vien, KE CA
    management account, bat ke recorder_target_ous la gi. Account
    khong co recorder thi rule khong bao gio tao duoc:

      NoAvailableConfigurationRecorder          <- account ngoai
                                                   recorder_target_ous
      UnableToAssumeServiceLinkedRoleException  <- management account,
                                                   chua tung bat Config

    Va no khong hong nhanh: rule nam o CREATE_IN_PROGRESS hang chuc
    phut roi moi thanh CREATE_FAILED, keo ca lan apply theo.

    QUY TAC: moi account ACTIVE khong nam trong recorder_target_ous
    thi PHAI co mat o day. Luon bao gom management account.
    ===============================================================

    Ngoai ra, sandbox va account thu nghiem cung nen dua vao - noi
    vi pham la chuyen binh thuong va bao dong chi tao nhieu.

    Doi chieu nhanh sau khi apply:
      aws configservice get-organization-config-rule-detailed-status \
        --organization-config-rule-name <ten-rule> \
        --profile <security> --region <region> \
        --query 'OrganizationConfigRuleDetailedStatus[].[AccountId,MemberAccountRuleStatus,ErrorCode]' \
        --output table
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

    ===============================================================
    MAC DINH FALSE, VA GAN NHU CHAC CHAN PHAI DE FALSE.

    AWS CONFIG KHONG GIAO DUOC FILE VAO BUCKET BAT OBJECT LOCK.

    Da kiem chung bang thuc nghiem: hai bucket giong het nhau ve
    policy, ve BucketOwnerEnforced, ve account nguon - khac moi
    Object Lock. Bucket khong khoa thi put-delivery-channel chay
    ngay; bucket khoa thi bao:

      InsufficientDeliveryPolicyException: unable to write to bucket

    Thong bao lo ra ten "DeliveryPolicy" nen rat de dan nguoi ta di
    sua bucket policy hang gio ma khong ra - policy hoan toan dung.
    Nguyen nhan la S3 doi header Content-MD5 tren moi PutObject vao
    bucket co Object Lock, va Config khong gui header do.
    ===============================================================

    Y DINH BAN DAU van dung: tach account log archive de account bi
    xam nhap khong xoa duoc bang chung, va Object Lock la cach manh
    nhat de dam bao dieu do. Nhung no khong dung duoc TRUC TIEP tren
    bucket ma Config giao vao.

    Muon ca hai thi phai them mot tang:

      Config -> bucket thuong -> S3 Replication -> bucket khoa

    Replication ghi vao bucket dich bang credential cua chinh S3, nen
    khong vuong rang buoc Content-MD5. Doi lai: them mot bucket, mot
    IAM role, va chi phi replication. Layer nay CHUA lam viec do.

    Lop bao ve con lai khi khong co Object Lock, van dang ke:
      - bucket nam o account RIENG (log archive)
      - versioning bat
      - baseline SCP chan xoa configuration recorder
      - public access block
  EOT
  type        = bool
  default     = false
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

########################################
# TEARDOWN
########################################

variable "allow_destroy" {
  description = <<-EOT
    Go moi lop bao ve PHIA AWS de destroy chay duoc.

    Layer nay: bat force_destroy cho bucket Config o log archive
    account. Bucket bat versioning nen khong co dong nay thi destroy
    dung lai voi BucketNotEmpty.

    KHONG go duoc lop chan lon nhat cua layer nay. Bao ve that nam o
    SCP "baseline" cua layer organization, chan o MOI account thanh
    vien:

      config:DeleteConfigurationRecorder
      config:StopConfigurationRecorder
      config:DeleteDeliveryChannel

    Recorder do StackSet tao trong account thanh vien, nen role thuc
    thi StackSet phai nam trong scp_exempt_role_names cua layer
    organization, va layer do phai duoc apply TRUOC khi destroy layer
    nay. Xem TEARDOWN.md muc 3 buoc 7.

    Con mot lop nua khong bien nao go duoc: prevent_destroy. Dung
    ./unlock-destroy.sh.
  EOT
  type        = bool
  default     = false
}

########################################
# SECURITY HUB
########################################

variable "enable_security_hub" {
  description = <<-EOT
    Bat Security Hub o pham vi to chuc.

    MAC DINH TAT - vi day la thu tinh tien, khac han SCP.

    ---------------------------------------------------------------
    NHUNG NEU DA KHAI alert_emails THI PHAI BAT.

    notify.tf khop event theo source = ["aws.securityhub"]. Khong bat
    Security Hub thi khong co su kien nao toi rule EventBridge, va ca
    duong canh bao nam im - khong loi, khong canh bao, khong gi ca.
    Co check "alerts_have_a_source" bat truong hop nay luc plan.
    ---------------------------------------------------------------

    DUOC GI: phan lon DETECTIVE control cua Control Tower la AWS Config
    managed rule, va Security Hub standard goi san chung. Bat FSBP cho
    do phu tuong duong ma khong can dung Control Tower.

    Con lai: PREVENTIVE control la SCP (layer organization), PROACTIVE
    control la CloudFormation Hook - chi chay khi resource duoc tao qua
    CloudFormation, nen khong dung toi voi mot to chuc dung Terraform.

    CHI PHI: tinh theo so lan kiem tra bao mat, moi account, moi region.
    Do o Cost Explorer voi Service = "AWS Security Hub" sau mot tuan
    truoc khi mo rong.
  EOT
  type        = bool
  default     = false
}

variable "security_hub_standards" {
  description = <<-EOT
    Standard bat tai security account. Ten ngan, khong phai ARN.

      fsbp          AWS Foundational Security Best Practices
      cis-1.4       CIS AWS Foundations Benchmark 1.4.0
      cis-3.0       CIS AWS Foundations Benchmark 3.0.0
      nist-800-53   NIST SP 800-53 Rev 5
      pci-dss       PCI DSS 3.2.1

    Bat DUNG MOT CAI truoc. Cac standard trung nhau rat nhieu, nen cai
    thu hai them it phat hien moi ma nhan doi so lan kiem tra phai tra
    tien. check "security_hub_costs_money" canh bao khi khai hon mot.

    CIS 1.2 KHONG co trong danh sach: ARN cua no dung duong dan
    "ruleset/..." va khong co region - khac khuon moi ban khac. No cung
    da bi thay the boi 1.4 va 3.0.
  EOT
  type        = list(string)
  default     = ["fsbp"]

  validation {
    condition = alltrue([
      for s in var.security_hub_standards :
      contains(["fsbp", "cis-1.4", "cis-3.0", "nist-800-53", "pci-dss"], s)
    ])
    error_message = "Chi nhan: fsbp, cis-1.4, cis-3.0, nist-800-53, pci-dss."
  }
}

variable "security_hub_auto_enable_new_accounts" {
  description = <<-EOT
    Account tao SAU co tu duoc bat Security Hub khong.

    Cung khuon voi auto_deployment cua StackSet ben account-baseline:
    thu gi phai nho lam tay cho tung account moi thi som muon cung bi
    quen o mot account nao do.
  EOT
  type        = bool
  default     = true
}

variable "security_hub_auto_enable_standards" {
  description = <<-EOT
    Standard nao tu bat o account thanh vien: "DEFAULT" hoac "NONE".

    AWS chi cho hai gia tri nay. DEFAULT = chi FSBP.

    Muon CIS hoac NIST tren MOI account thanh vien thi bien nay KHONG
    lam duoc - phai dung central configuration policy (API moi hon)
    hoac dang ky tung account. security_hub_standards o tren CHI ap
    cho security account.
  EOT
  type        = string
  default     = "DEFAULT"

  validation {
    condition     = contains(["DEFAULT", "NONE"], var.security_hub_auto_enable_standards)
    error_message = "Chi nhan DEFAULT hoac NONE."
  }
}
