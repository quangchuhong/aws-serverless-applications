########################################
# GUARDDUTY
#
# Bo sung tang con thieu cua lop phat hien:
#
#   AWS Config    trang thai CAU HINH co dung chuan khong
#   GuardDuty     co HANH VI bat thuong dang xay ra khong
#
# Hai cau hoi khac han nhau. Config khong bao gio phat hien duoc mot
# instance dang dao coin hay mot credential dang bi dung tu IP la -
# cau hinh cua chung van dung chuan.
#
# ---------------------------------------------------------------
# KHONG CAN THEM DUONG CANH BAO NAO
#
# GuardDuty tu day finding sang Security Hub, va notify.tf da doc
# tu Security Hub roi. Nen bat GuardDuty la finding tu chay vao
# dung SNS topic dang co - khong phai dung them EventBridge rule.
#
# Doi lai: TAT Security Hub thi finding cua GuardDuty KHONG toi ai.
# check "guardduty_findings_reach_someone" bat truong hop do.
# ---------------------------------------------------------------
#
# CHI PHI - khac Config o cho tinh theo GI
#
#   Config      theo so configuration item ghi duoc
#   GuardDuty   theo LUONG LOG phan tich: CloudTrail management event,
#               VPC Flow Log, DNS log
#
# Phan nen thuong khiem ton. Cho tien nhay la cac FEATURE them:
# S3 Protection, Malware Protection, EKS, RDS, Lambda - moi cai mot
# nguon du lieu rieng va mot hoa don rieng. Vi vay guardduty_features
# mac dinh RONG - va muc 4 khai ca hai chieu de "rong" that su la TAT,
# chu khong phai "khong dong toi". AWS bat san phan lon chung.
#
# Moi account co 30 ngay dung thu moi region. Do chi phi that o
# console sau khi het thu, dung uoc luong.
########################################

locals {
  gd = local.enabled && var.enable_guardduty ? 1 : 0

  # MOI feature tat duoc, khong chi cai duoc chon.
  #
  # VI SAO PHAI LIET KE CA DANH SACH - loi 37:
  # AWS BAT SAN phan lon feature tinh tien khi tao detector. Neu chi
  # sinh resource cho cac feature trong guardduty_features thi
  # guardduty_features = [] tao ra KHONG resource nao, va "khong
  # resource nao" nghia la "Terraform khong quan", KHONG phai "tat".
  # Ket qua do o mot detector that:
  #
  #   S3_DATA_EVENTS          ENABLED
  #   EKS_AUDIT_LOGS          ENABLED
  #   EBS_MALWARE_PROTECTION  ENABLED
  #   RDS_LOGIN_EVENTS        ENABLED
  #   LAMBDA_NETWORK_LOGS     ENABLED
  #
  # Nam dong hoa don, trong khi tai lieu cua chinh file nay ghi "mac
  # dinh khong bat cai nao" va check guardduty_features_cost_money dem
  # length(var.guardduty_features) = 0 nen im lang.
  #
  # Liet ke ca danh sach thi [] moi that su la TAT HET.
  #
  # CLOUD_TRAIL / DNS_LOGS / FLOW_LOGS khong co o day: do la phan nen,
  # luon chay va khong tat duoc.
  gd_manageable_features = [
    "S3_DATA_EVENTS",
    "EKS_AUDIT_LOGS",
    "EBS_MALWARE_PROTECTION",
    "RDS_LOGIN_EVENTS",
    "LAMBDA_NETWORK_LOGS",
    "RUNTIME_MONITORING",
  ]

  gd_features = local.gd == 0 ? {} : {
    for f in local.gd_manageable_features : f => contains(var.guardduty_features, f)
  }
}

########################################
# 1. Chi dinh delegated admin - TU MANAGEMENT ACCOUNT
#
# Giong het Security Hub, va la cung mot bay: dang ky
# guardduty.amazonaws.com trong aws_organizations_delegated_administrator
# la CHUA DU. GuardDuty co lenh chi dinh rieng, va thieu no thi moi
# lenh goi tu security account bao khong phai admin.
#
# KHAC Security Hub o mot cho quan trong: doi admin sang account khac
# SAU KHI da co member dang enable thi KHONG DOI DUOC - phai go het
# member truoc. Chon account mot lan, chon dung.
########################################

resource "aws_guardduty_organization_admin_account" "this" {
  count = local.gd

  admin_account_id = var.security_account_id
}

########################################
# 2. Detector o security account
#
# Detector la "cong tac bat" cua GuardDuty trong mot account + region.
# Khong co no thi khong co gi phan tich.
########################################

resource "aws_guardduty_detector" "security" {
  count    = local.gd
  provider = aws.security

  enable = true

  # Tan suat gui finding DA CO sang EventBridge khi no duoc cap nhat.
  # Finding MOI luon day ngay lap tuc, bat ke gia tri nay.
  #
  # SIX_HOURS la mac dinh cua AWS. Dat FIFTEEN_MINUTES cho finding
  # duoc cap nhat nhanh hon - khong doi chi phi, vi tien tinh theo
  # luong log phan tich chu khong theo so lan gui.
  finding_publishing_frequency = var.guardduty_publishing_frequency

  depends_on = [aws_guardduty_organization_admin_account.this]
}

########################################
# 3. Account thanh vien
#
# auto_enable_organization_members quyet dinh account nao duoc bat:
#
#   ALL    moi account hien tai VA tuong lai
#   NEW    chi account tao SAU thoi diem nay
#   NONE   khong tu bat cho ai
#
# ALL la lua chon dung cho mot lop phat hien: mot account khong duoc
# giam sat la mot cho ke tan cong o lai ma khong ai thay. Khac Config
# o cho nay - Config tinh tien theo khoi luong ghi nen dang chon loc
# OU, con GuardDuty thi khoang trong nguy hiem hon khoan tiet kiem.
########################################

resource "aws_guardduty_organization_configuration" "this" {
  count    = local.gd
  provider = aws.security

  detector_id                      = aws_guardduty_detector.security[0].id
  auto_enable_organization_members = var.guardduty_auto_enable_members
}

########################################
# 4. Feature them - KHAI BAO CA HAI CHIEU
#
# Moi feature la mot nguon du lieu rieng va mot dong hoa don rieng.
# S3 Protection va Malware Protection la hai cai dat nhat.
#
# Ca hai resource duoi day duyet HET local.gd_manageable_features chu
# khong chi cac feature duoc chon: cai co trong guardduty_features thi
# BAT, cai khong co thi TAT tuong minh. Do la cach duy nhat de
# guardduty_features = [] co nghia dung nhu tai lieu noi - xem loi 37.
#
# CANH BAO KHI AP LAN DAU LEN MOT DETECTOR DA CHAY:
# apply se TAT that cac feature dang bat. Kiem truoc bang
#   aws guardduty get-detector --detector-id <id> --query 'Features'
# roi dua cai muon giu vao guardduty_features TRUOC khi apply.
#
# Bat TUNG CAI MOT, do mot tuan o Cost Explorer roi moi them tiep -
# cung cach lam voi Security Hub standard.
#
# ---------------------------------------------------------------
# VI SAO CAN HAI RESOURCE, KHONG PHAI MOT
#
#   aws_guardduty_detector_feature              detector cua CHINH
#                                               security account
#   aws_guardduty_organization_configuration_feature
#                                               mac dinh cho ACCOUNT
#                                               THANH VIEN
#
# Chung goi hai API khac nhau. Chi khai cai thu hai thi account thanh
# vien sach se con chinh detector cua security account van bat day du
# feature tinh tien - va do la detector duy nhat ban nhin thay khi go
# lenh get-detector, nen sai sot nay rat de tu ru ngu minh.
#
# ---------------------------------------------------------------
# NHUNG SCP CHAN CAI THU NHAT - VA DO LA HANH VI DUNG. Loi 38.
#
#   AccessDeniedException: ... guardduty:UpdateDetector ...
#   with an explicit deny in a service control policy: p-...
#
# SCP deny_guardrails (statement ProtectAuditTrail, layer organization)
# co guardduty:UpdateDetector trong danh sach cam. Ma UpdateDetector la
# API DUY NHAT de doi feature - AWS khong tach "tat detector" khoi
# "doi feature". Guardrail chan ca hai.
#
# Chan Terraform TAT feature la dung: tat feature la lam yeu lop phat
# hien, chinh thu SCP sinh ra de chan. Viec no chan luon chieu BAT chi
# la thiet hai kem theo, va AWS khong cho phan biet.
#
# => Mac dinh KHONG quan detector cua security account. Xem bien
#    guardduty_manage_admin_detector_features.
#
# DUNG mien tru OrganizationAccountAccessRole de vuot qua. Do la chia
# khoa van nang vao moi member account; mien tru no khoi SCP baseline
# thi ai cam no cung StopLogging, DeleteTrail, DeleteDetector,
# CloseAccount duoc - toan bo deny_guardrails sup theo. Neu that su
# can, tao mot role RIENG cho pipeline va chi mien tru role do.
#
# CHI PHI: phan tien that nam o ACCOUNT THANH VIEN, va resource thu
# hai lo viec do - no goi UpdateOrganizationConfiguration, mot action
# KHAC, khong bi SCP chan. Detector con lai la cua security account,
# noi khong chay workload. Do o Cost Explorer truoc khi lo lang.
# ---------------------------------------------------------------

resource "aws_guardduty_detector_feature" "security" {
  for_each = var.guardduty_manage_admin_detector_features ? local.gd_features : {}
  provider = aws.security

  detector_id = aws_guardduty_detector.security[0].id
  name        = each.key
  status      = each.value ? "ENABLED" : "DISABLED"
}

resource "aws_guardduty_organization_configuration_feature" "this" {
  for_each = local.gd_features
  provider = aws.security

  detector_id = aws_guardduty_detector.security[0].id
  name        = each.key
  auto_enable = each.value ? "ALL" : "NONE"

  depends_on = [aws_guardduty_organization_configuration.this]
}

########################################
# KIEM TRA CHEO
########################################

# GuardDuty khong co duong canh bao rieng. No di nho Security Hub.
check "guardduty_findings_reach_someone" {
  assert {
    condition = local.gd == 0 || var.enable_security_hub
    error_message = join(" ", [
      "GuardDuty bat nhung enable_security_hub = false.",
      "GuardDuty KHONG co duong canh bao rieng trong layer nay - finding",
      "cua no di nho Security Hub, va notify.tf khop event theo",
      "source = aws.securityhub.",
      "Security Hub co the dang chay ngoai Terraform (xem",
      "check alerts_have_a_source), nhung neu khong thi ban dang tra tien",
      "cho GuardDuty phan tich log ma khong ai doc ket qua.",
      "Kiem: aws securityhub describe-hub --profile <security> --region <region>",
    ])
  }
}

check "admin_detector_features_need_an_scp_exemption" {
  assert {
    condition = local.gd == 0 || !var.guardduty_manage_admin_detector_features
    error_message = join(" ", [
      "guardduty_manage_admin_detector_features = true.",
      "aws_guardduty_detector_feature goi guardduty:UpdateDetector, ma SCP",
      "deny_guardrails (statement ProtectAuditTrail) cam action do -",
      "apply se bao AccessDeniedException voi 'explicit deny in a service",
      "control policy'.",
      "Chi bat khi principal chay Terraform DA nam trong",
      "scp_exempt_role_names cua layer organization.",
      "DUNG them OrganizationAccountAccessRole vao danh sach do: no la",
      "chia khoa van nang vao moi member account, mien tru no lam sup ca",
      "deny_guardrails. Tao mot role rieng cho pipeline neu can.",
      "Nho: feature cua ACCOUNT THANH VIEN khong can bien nay - resource",
      "aws_guardduty_organization_configuration_feature dung mot action",
      "khac va khong bi chan.",
    ])
  }
}

check "guardduty_features_cost_money" {
  assert {
    condition = length(var.guardduty_features) <= 1
    error_message = join(" ", [
      "Dang bat", tostring(length(var.guardduty_features)),
      "feature cung luc. Moi feature la mot nguon du lieu rieng va mot",
      "dong hoa don rieng - S3_DATA_EVENTS va EBS_MALWARE_PROTECTION la",
      "hai cai dat nhat.",
      "Bat mot cai, do mot tuan o Cost Explorer (Service = Amazon GuardDuty),",
      "roi moi them cai tiep theo.",
    ])
  }
}
