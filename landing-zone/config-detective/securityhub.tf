########################################
# SECURITY HUB
#
# VI SAO FILE NAY TON TAI - doc truoc khi bat:
#
# notify.tf khop event theo source = ["aws.securityhub"]. Khong bat
# Security Hub thi KHONG CO SU KIEN NAO toi rule do, va ca duong
# canh bao - EventBridge, SNS, email da xac nhan - nam im.
#
# Khong co gi bao loi. terraform apply xanh, SNS co subscriber that,
# rule EventBridge ton tai. Chi la khong bao gio co gi di qua.
#
# ---------------------------------------------------------------
# CHI PHI - KHONG PHAI $0 NHU SCP
#
# Security Hub tinh theo SO LAN KIEM TRA bao mat, moi account, moi
# region. Mot standard co hang tram control, chay lai moi khi resource
# doi. 5 account x 2 region x FSBP la con so that.
#
# Vi vay mac dinh TAT. Bat mot standard, do mot tuan, roi moi them.
#
# ---------------------------------------------------------------
# QUAN HE VOI CONTROL TOWER
#
# Phan lon DETECTIVE control cua Control Tower la AWS Config managed
# rule - va Security Hub standard goi san chung. Bat FSBP o day cho
# do phu tuong duong ma khong can dung Control Tower.
#
# PREVENTIVE control thi la SCP - xem layer organization.
# PROACTIVE control la CloudFormation Hook, CHI chay khi resource
# duoc tao qua CloudFormation, nen vo nghia voi mot to chuc dung
# Terraform.
########################################

locals {
  sh = local.enabled && var.enable_security_hub ? 1 : 0

  # ARN cua standard KHONG cung mot khuon.
  #
  # CIS 1.2 dung duong dan "ruleset/..." va KHONG co region - khac
  # han cac ban sau. Co y khong dua vao day: no da bi thay the, va
  # mot ngoai le trong map se de sinh loi hon la loi ich.
  sh_standard_arns = {
    "fsbp"        = "arn:${data.aws_partition.current.partition}:securityhub:${var.region}::standards/aws-foundational-security-best-practices/v/1.0.0"
    "cis-1.4"     = "arn:${data.aws_partition.current.partition}:securityhub:${var.region}::standards/cis-aws-foundations-benchmark/v/1.4.0"
    "cis-3.0"     = "arn:${data.aws_partition.current.partition}:securityhub:${var.region}::standards/cis-aws-foundations-benchmark/v/3.0.0"
    "nist-800-53" = "arn:${data.aws_partition.current.partition}:securityhub:${var.region}::standards/nist-800-53/v/5.0.0"
    "pci-dss"     = "arn:${data.aws_partition.current.partition}:securityhub:${var.region}::standards/pci-dss/v/3.2.1"
  }

  sh_selected = local.sh == 1 ? {
    for s in var.security_hub_standards : s => local.sh_standard_arns[s]
  } : {}
}

########################################
# 1. Bat o MANAGEMENT account
#
# EnableOrganizationAdminAccount goi tu management account, va doi
# Security Hub da bat o chinh account do. Nen buoc nay dung truoc
# viec uy quyen, khong phai sau.
########################################

resource "aws_securityhub_account" "management" {
  count = local.sh

  # Management account khong chay workload, nen tat het cai tu bat.
  # No chi can ton tai de uy quyen duoc.
  enable_default_standards = false
  auto_enable_controls     = false
}

########################################
# 2. Uy quyen sang security account
#
# LOI 14 CUA DOC 22 NAM O DAY.
#
# Dang ky securityhub.amazonaws.com trong aws_organizations_delegated_
# administrator (layer organization) la CHUA DU. Security Hub co lenh
# chi dinh RIENG, va thieu no thi moi lenh goi tu security account bao:
#
#   InvalidAccessException: The account is not an administrator
#
# Thong bao do khong nhac gi toi Organizations, nen rat de di tim sai cho.
########################################

resource "aws_securityhub_organization_admin_account" "this" {
  count = local.sh

  admin_account_id = var.security_account_id

  depends_on = [aws_securityhub_account.management]
}

########################################
# 3. Bat o security account - noi gom finding
########################################

resource "aws_securityhub_account" "security" {
  count    = local.sh
  provider = aws.security

  enable_default_standards = false # chon tuong minh o muc 5
  auto_enable_controls     = true

  depends_on = [aws_securityhub_organization_admin_account.this]
}

########################################
# 4. Account thanh vien
#
# auto_enable = true thi account TAO SAU tu duoc bat - cung khuon
# voi auto_deployment cua StackSet o account-baseline.
#
# GIOI HAN PHAI BIET: auto_enable_standards chi nhan DEFAULT hoac
# NONE. DEFAULT = chi FSBP. Muon CIS hay NIST tren MOI account thanh
# vien thi phai dung central configuration policy (API moi hon), hoac
# dang ky tung account. Muc 5 duoi day CHI ap cho security account.
########################################

resource "aws_securityhub_organization_configuration" "this" {
  count    = local.sh
  provider = aws.security

  auto_enable           = var.security_hub_auto_enable_new_accounts
  auto_enable_standards = var.security_hub_auto_enable_standards

  depends_on = [aws_securityhub_account.security]
}

########################################
# 5. Standard - tai security account
########################################

resource "aws_securityhub_standards_subscription" "this" {
  for_each = local.sh_selected
  provider = aws.security

  standards_arn = each.value

  depends_on = [aws_securityhub_account.security]
}

########################################
# 6. Gom finding tu nhieu region ve mot cho
#
# Khong co cai nay thi phai mo console tung region moi thay het -
# dung kieu mu ma aggregator cua Config sinh ra de tranh.
########################################

resource "aws_securityhub_finding_aggregator" "this" {
  count    = local.sh
  provider = aws.security

  linking_mode      = "SPECIFIED_REGIONS"
  specified_regions = [for r in var.aggregator_regions : r if r != var.region]

  depends_on = [aws_securityhub_account.security]
}

########################################
# KIEM TRA CHEO
########################################

# Kieu hong dat nhat cua ca layer: duong canh bao day du nhung
# khong co nguon.
check "alerts_have_a_source" {
  assert {
    condition = !local.enabled || length(var.alert_emails) == 0 || var.enable_security_hub
    error_message = join(" ", [
      "alert_emails da khai nhung enable_security_hub = false.",
      "notify.tf khop event theo source = aws.securityhub, nen KHONG CO",
      "su kien nao toi rule EventBridge va khong ai nhan duoc gi -",
      "du SNS co subscriber da xac nhan. Bat enable_security_hub,",
      "hoac bo alert_emails de khoi tuong minh dang duoc canh bao.",
    ])
  }
}

check "security_hub_costs_money" {
  assert {
    condition = !var.enable_security_hub || length(var.security_hub_standards) <= 1
    error_message = join(" ", [
      "Dang bat", tostring(length(var.security_hub_standards)),
      "standard cung luc. Security Hub tinh theo SO LAN KIEM TRA moi",
      "account moi region - moi standard them vao la nhan len.",
      "Bat mot cai, do mot tuan o Cost Explorer (Service = AWS Security Hub),",
      "roi moi them cai tiep theo.",
    ])
  }
}
