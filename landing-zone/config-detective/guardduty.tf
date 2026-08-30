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
# mac dinh RONG.
#
# Moi account co 30 ngay dung thu moi region. Do chi phi that o
# console sau khi het thu, dung uoc luong.
########################################

locals {
  gd = local.enabled && var.enable_guardduty ? 1 : 0
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
# 4. Feature them - MAC DINH KHONG BAT CAI NAO
#
# Moi feature la mot nguon du lieu rieng va mot dong hoa don rieng.
# S3 Protection va Malware Protection la hai cai dat nhat.
#
# Bat TUNG CAI MOT, do mot tuan o Cost Explorer roi moi them tiep -
# cung cach lam voi Security Hub standard.
########################################

resource "aws_guardduty_organization_configuration_feature" "this" {
  for_each = local.gd == 1 ? toset(var.guardduty_features) : []
  provider = aws.security

  detector_id = aws_guardduty_detector.security[0].id
  name        = each.value
  auto_enable = "ALL"

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
