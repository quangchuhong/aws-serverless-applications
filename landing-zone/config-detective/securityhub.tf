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
# DAY KHONG PHAI DIEU KIEN TIEN QUYET - trang thai that da chung minh.
#
# Ban dau file nay ghi rang EnableOrganizationAdminAccount doi Security
# Hub phai bat san o management account. SAI. Do thay duoc bang hai
# lenh, tren chinh to chuc nay:
#
#   aws securityhub describe-hub                      (management)
#     -> InvalidAccessException: Account ... is not subscribed
#   aws securityhub list-organization-admin-accounts  (management)
#     -> 458195083898  ENABLED
#
# Uy quyen dang chay, management chua bao gio subscribe. Xem loi 36
# cua doc 22.
#
# ---------------------------------------------------------------
# VAY VI SAO VAN GIU RESOURCE NAY?
#
# Khong phai de uy quyen duoc, ma de management account DUOC GIAM SAT.
#
# auto_enable = true o muc 4 KHONG voi toi management account - cung
# hai lenh tren la bang chung: auto_enable da bat tu lau va management
# van khong subscribe. Khong bat o day thi khong ai bat no.
#
# Va day la account dang tiec nhat neu bo sot: no giu Organizations,
# SCP, va hoa don - dong thoi la account duy nhat SCP KHONG BAO GIO
# ap duoc. No can lop phat hien HON cac account khac, khong phai kem hon.
#
# ---------------------------------------------------------------
# HE QUA KHI APPLY: day la thay doi THAT, khong phai import.
#
# Neu ban dang co Security Hub bat bang tay o security account roi thi
# ba resource kia import duoc, rieng dong nay se TAO MOI - tuc la
# subscribe them mot account. Chi phi nho (khong standard, khong tu bat
# control) nhung khac khong.
#
# Khong muon thi: enable_default_standards/auto_enable_controls khong
# giup gi - phai bo han resource nay va dong depends_on o muc 2.
########################################

resource "aws_securityhub_account" "management" {
  count = local.sh

  # Management account khong chay workload. Bat het muc dich la giam
  # sat chinh no, khong phai chay hang tram control tinh tien o day.
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

  # KHONG phai rang buoc ky thuat - muc 1 da noi ro no khong phai dieu
  # kien tien quyet. Giu lai vi mot ly do khac: no dinh thu tu DESTROY.
  #
  # Terraform go theo chieu nguoc, nen dong nay bao dam bo uy quyen
  # TRUOC khi tat Security Hub o management. Bo dong nay thi hai viec
  # do chay song song, va thu tu ngau nhien la thu tu se hong o mot lan
  # destroy nao do chu khong phai lan nay.
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
# 4b. Ghi danh TUNG account - vi muc 4 chi lo cho account TAO SAU
#
# LOI 45. Do duoc bang mot lenh:
#
#   aws securityhub list-members --no-only-associated --profile <security>
#   -> { "Members": [] }
#
# auto_enable = true o muc 4, uy quyen tron ven, aggregator chay,
# email canh bao toi that - va KHONG account thanh vien nao duoc ghi
# danh. auto_enable la chinh sach cho account TAO SAU thoi diem bat;
# nam account da ton tai truoc do khong bao gio duoc goi CreateMembers.
#
# CUNG HINH DANG VOI LOI 41 ben GuardDuty, va cung cach vao:
# chinh sach lo tuong lai, resource nay lo hien tai. Hai co che bo tro
# nhau chu khong thay the nhau.
#
# ---------------------------------------------------------------
# HAU QUA KHI THIEU - khong phai "khong co gi hoat dong"
#
# Finding cua GuardDuty VAN toi: chung di thang vao Security Hub cua
# delegated admin, khong qua Security Hub cua account thanh vien.
# Do la ly do duong canh bao van gui duoc email that va lo hong nay
# van an duoc.
#
# Thu KHONG toi la finding sinh TRONG account thanh vien - dien hinh
# la ket qua danh gia cua Config rule. Chung tro thanh finding trong
# chinh account do, ma account do chua bat Security Hub.
#
# => Duong canh bao dang mang MOT trong HAI nguon.
########################################

resource "aws_securityhub_member" "this" {
  for_each = local.sh == 0 ? {} : {
    for a in data.aws_organizations_organization.this.accounts :
    a.id => a.email
    if a.status == "ACTIVE" && a.id != var.security_account_id
  }

  provider = aws.security

  account_id = each.key
  email      = each.value

  # Account trong CUNG to chuc duoc nhan thang. Dat true thi Security
  # Hub gui loi moi toi email root - ma email cua cac LZ account la
  # dia chi plus-addressing khong ai doc.
  invite = false

  depends_on = [aws_securityhub_organization_configuration.this]

  # PHONG THEO LOI 42, chua do rieng cho resource nay.
  #
  # aws_guardduty_member co dung hai truong nay va ca hai deu gay
  # REPLACE moi lan plan: email khong duoc doc lai tu API nen state
  # rong trong khi config co gia tri, ma email la ForceNew; invite thi
  # provider suy tu trang thai member nen luon doc ra true.
  #
  # Chua chac aws_securityhub_member hanh xu y het. Nhung phep danh
  # doi lech han mot phia: neu thua thi vo hai, neu thieu thi moi lan
  # plan doi GO 5 account that ra khoi Security Hub roi ket nap lai.
  #
  # KIEM: sau khi apply, chay plan lan hai. Ra "No changes" la xong.
  lifecycle {
    ignore_changes = [email, invite]
  }
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
      "alert_emails da khai nhung enable_security_hub = false, nghia la",
      "NGUON cua duong canh bao KHONG DO LAYER NAY QUAN.",
      "notify.tf khop event theo source = aws.securityhub.",
      "Security Hub co the dang chay - RUNBOOK giai doan 7 co ba lenh bat",
      "bang tay - nhung Terraform khong biet, va khong ai bao neu no tat.",
      "HOI THANG DICH VU, dung suy tu plan:",
      "aws securityhub describe-hub --profile <security> --region <region>",
      "Ra HubArn = duong canh bao co nguon.",
      "Ra InvalidAccessException = khong ai nhan duoc gi, du SNS co",
      "subscriber da xac nhan.",
      "Dat enable_security_hub = true de Terraform quan luon nguon do.",
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
