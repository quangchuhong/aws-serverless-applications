########################################
# CONFIG RULE - va CHI Config rule
#
# =======================================================================
# CHIEU: XOA MOT RULE LA NOI, VA THEM VAO excluded_accounts CUNG LA NOI
#
# Cai thu hai nguoc voi truc giac: mot tap hop LON LEN lai la noi long.
# Moi account them vao excluded_accounts la mot account thoat khoi phep
# kiem - va no thoat trong IM LANG, vi rule van "dang bat" va console van
# hien no xanh.
#
# gate.py biet chieu do (tap_khong_lon, muc
# aws_config_organization_managed_rule).
#
# =======================================================================
# NHUNG GI PIPELINE NAY KHONG DUOC CHAM
#
# Layer config-detective quan ca recorder, aggregator, Security Hub,
# GuardDuty, bucket log va duong bao dong. Chung doi vai lan mot nam, va
# mot pipeline tu apply duoc chung la mot pipeline co the TAT CA HE THONG
# PHAT HIEN cua to chuc trong mot lan chay.
#
# -target giu lai dung mot resource. local.tu_choi_dich_vu viet ro phan
# con lai - vi mot nguoi doc danh sach Allow khong biet duoc thu gi CO Y
# khong cho.
########################################

locals {
  stages = [
    {
      key     = "cloudops-config-rules"
      layer   = "landing-zone/config-detective"
      enabled = var.enable_config_rules_stage

      targets = [
        "aws_config_organization_managed_rule.this",
      ]

      khong_co_lint = "config-detective khai rule trong bien organization_rules, chua co catalog - phep kiem y nghia la gate.py, muc aws_config_organization_managed_rule"

      mo_ta = "Config rule toan to chuc. Xoa mot rule, hoac THEM account vao excluded_accounts, deu la NOI."
    },
  ]

  catalogs = []

  khong_co_catalog = "config-detective khai rule bang bien organization_rules trong tfvars, chua co catalog YAML. Khi catalog hoa thi them vao local.catalogs va XOA dong nay."

  ####################################
  # QUYEN
  #
  # Config rule song o ACCOUNT SECURITY, qua provider aws.security co
  # assume_role. Nen quyen THAT nam o role dich; role nay chi can assume
  # duoc sang no.
  #
  # Phan doc o day danh cho nhung gi layer cham TU ACCOUNT MANAGEMENT:
  # aws_securityhub_account.management va aws_guardduty_detector.management
  # dung provider mac dinh, va plan refresh ca chung.
  ####################################
  ####################################
  # STATE LAYER NAY DOC CUA LAYER KHAC
  #
  # config-detective/vending.tf doc state cua account-baseline qua
  # terraform_remote_state (bien vending_state).
  #
  # Khong khai thi plan CHET voi mot loi 403 cua S3 tren khoa do - va
  # loi do khong nhac gi toi terraform_remote_state. Da vuong that o
  # pipeline permission-set.
  #
  # CHI DOC: module cap dung s3:GetObject.
  ####################################
  state_chi_doc = [
    "account-baseline/terraform.tfstate",
  ]

  quyen_dich_vu = [
    {
      Sid      = "AssumeVaoSecurityVaLogArchive"
      Effect   = "Allow"
      Action   = ["sts:AssumeRole"]
      Resource = var.config_pipeline_role_arns
    },
    {
      Sid    = "DocPhanNamOManagement"
      Effect = "Allow"
      Action = [
        "securityhub:Get*",
        "securityhub:Describe*",
        "securityhub:List*",
        "guardduty:Get*",
        "guardduty:List*",
        "guardduty:Describe*",
        "config:Describe*",
        "config:Get*",
        "config:List*",
        "organizations:Describe*",
        "organizations:List*",
      ]
      Resource = "*"
    },
  ]

  ####################################
  # PHAM VI THAT CUA KHOI DENY NAY - DOC TRUOC KHI TIN NO
  #
  # Deny duoi day gan vao role CodeBuild o ACCOUNT MANAGEMENT. Sau
  # `sts:AssumeRole`, phien moi mang quyen cua ROLE DICH, va policy cua
  # danh tinh goi KHONG di theo.
  #
  # Nen no CHI rang buoc nhung goi API layer nay thuc hien TRUC TIEP bang
  # danh tinh cua CodeBuild, tuc trong account management. Voi nhung
  # resource nam o account khac - qua provider alias co assume_role - no
  # KHONG co tac dung.
  #
  # Va role dich hien tai la OrganizationAccountAccessRole: FULL ADMIN
  # trong account do. Day la QUYET DINH TAM THOI da duoc thong qua - cho
  # cac pipeline chay on roi thu hep sau - khong phai mot cho bo sot.
  #
  # CACH CHUA, khi den luc: `assume_role` cua provider AWS nhan mot
  # SESSION POLICY (truong `policy`). Session policy giao voi quyen cua
  # role dich, nen Deny dat o do rang buoc dung phien dang lam viec. Do
  # la cho DUY NHAT mot Deny co tac dung cho cong viec lien account.
  #
  # GIU khoi nay chu khong xoa: no van co tac dung cho phan chay trong
  # account management, va no ghi lai Y DINH - danh sach nay la ban thao
  # cua session policy tuong lai.
  ####################################
  tu_choi_dich_vu = [
    {
      Sid    = "KhongTatHeThongPhatHien"
      Effect = "Deny"
      Action = [
        # Bon dong dau: tat ca he thong phat hien cua to chuc trong mot
        # lenh. Khong cai nao trong so do la viec hang ngay.
        "securityhub:DisableSecurityHub",
        "securityhub:DisableOrganizationAdminAccount",
        "guardduty:DeleteDetector",
        "guardduty:DisableOrganizationAdminAccount",

        # Recorder: tat no thi moi Config rule con lai khong co du lieu,
        # va chung van hien "dang bat".
        "config:DeleteConfigurationRecorder",
        "config:StopConfigurationRecorder",
        "config:DeleteDeliveryChannel",
        "config:DeleteConfigurationAggregator",

        # Uy quyen quan tri - la quyen, khong phai cau hinh.
        "organizations:RegisterDelegatedAdministrator",
        "organizations:DeregisterDelegatedAdministrator",
      ]
      Resource = "*"
    },
  ]
}

########################################
# BAT STAGE THI PHAI CO ROLE - DANH SACH RONG LA MOT CAI BAY
#
# config_pipeline_role_arns nuoi truong Resource cua statement
# sts:AssumeRole. Danh sach RONG lam Resource thanh [], va IAM tu choi CA
# POLICY voi mot loi ve dinh dang ARN - khong nhac gi toi bien nao.
#
# Va no khong hien ra o plan: plan van xanh, resource van duoc mo ta day
# du. Loi chi den luc APPLY, o buoc tao aws_iam_role_policy.
#
# Cach doc nhanh mot ban plan xem co dinh bay nay khong:
#   grep -c "OrganizationAccountAccessRole" <file plan>
# Ra 0 nghia la khong co ARN nao - stage se khong assume duoc sang
# account SECURITY va LOG-ARCHIVE.
########################################
check "bat_stage_thi_co_role" {
  assert {
    condition     = !var.enable || !var.enable_config_rules_stage || length(var.config_pipeline_role_arns) > 0
    error_message = join(" ", [
      "Stage dang duoc bat nhung config_pipeline_role_arns RONG.",
      "Statement sts:AssumeRole se co Resource = [], va IAM tu choi ca policy",
      "voi mot loi ve dinh dang ARN khong nhac toi bien nao. Dien ARN role o",
      "account SECURITY va LOG-ARCHIVE, hoac tat stage.",
    ])
  }
}

module "pipeline" {
  source = "../../modules/tf-pipeline"

  ten     = "ops-config-rules"
  enable  = var.enable
  project = var.project
  region  = var.region

  stages           = local.stages
  catalogs         = local.catalogs
  khong_co_catalog = local.khong_co_catalog
  state_chi_doc    = local.state_chi_doc
  quyen_dich_vu    = local.quyen_dich_vu
  tu_choi_dich_vu  = local.tu_choi_dich_vu

  source_type       = var.source_type
  repository_name   = var.repository_name
  branch_name       = var.branch_name
  tu_kich_hoat      = var.tu_kich_hoat
  source_bucket     = var.source_bucket
  source_object_key = var.source_object_key

  state_bucket     = var.state_bucket
  state_lock_table = var.state_lock_table
  layer_keys       = var.layer_keys
  tfvars_bucket    = var.tfvars_bucket

  approve_stages  = var.approve_stages
  approval_emails = var.approval_emails

  drift_cron      = var.drift_cron
  drift_emails    = var.drift_emails
  drift_topic_arn = var.drift_topic_arn

  expiry_blocks_pipeline = var.expiry_blocks_pipeline
  build_timeout_minutes  = var.build_timeout_minutes
  log_retention_days     = var.log_retention_days
}
