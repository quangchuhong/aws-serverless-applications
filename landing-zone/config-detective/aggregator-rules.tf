########################################
# AGGREGATOR - o account SECURITY TOOLING
#
# Day la manh con thieu trong ban ve ban dau.
#
# Snapshot trong S3 la DU LIEU THO - no khong tra loi duoc
# "hien co bao nhieu resource dang vi pham rule X".
# Aggregator moi la thu cung cap view do, va la nguon du lieu cho
# moi dashboard tuan thu.
#
# Aggregator gan nhu khong ton tien - tien nam o account DANG GHI,
# khong nam o cho tong hop.
########################################

data "aws_iam_policy_document" "aggregator_assume" {
  count = local.enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aggregator" {
  count    = local.enabled ? 1 : 0
  provider = aws.security

  name               = "${var.project}-config-aggregator"
  assume_role_policy = data.aws_iam_policy_document.aggregator_assume[0].json
}

resource "aws_iam_role_policy_attachment" "aggregator" {
  count    = local.enabled ? 1 : 0
  provider = aws.security

  role       = aws_iam_role.aggregator[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSConfigRoleForOrganizations"
}

resource "aws_config_configuration_aggregator" "org" {
  count    = local.enabled ? 1 : 0
  provider = aws.security

  name = "${var.project}-org"

  organization_aggregation_source {
    role_arn = aws_iam_role.aggregator[0].arn

    # KHONG dung all_regions = true - no gom ca region ban khong dung
    # va lam mo mat cai nhin ve chi phi.
    all_regions = false
    regions     = var.aggregator_regions
  }

  depends_on = [aws_iam_role_policy_attachment.aggregator]
}

########################################
# ORGANIZATION MANAGED RULE
#
# MOT resource, ap cho MOI account trong to chuc.
#
# Khac han voi viec tao aws_config_config_rule o tung account:
# khong phai nhan len theo so account, va account moi tu dong duoc
# ap ma khong can chay lai gi.
#
# DIEU KIEN TIEN QUYET: da uy quyen CA HAI service principal
#   config.amazonaws.com
#   config-multiaccountsetup.amazonaws.com
# o landing-zone/organization (bien delegated_administrators).
# Thieu cai thu hai -> AccessDeniedException khong noi ro nguyen nhan.
########################################

resource "aws_config_organization_managed_rule" "this" {
  for_each = local.enabled ? var.organization_rules : {}
  provider = aws.security

  name            = each.key
  rule_identifier = each.value

  # Sandbox / dev: vi pham la chuyen binh thuong, bao dong chi tao nhieu
  excluded_accounts = var.excluded_accounts

  ####################################
  # 5 PHUT MAC DINH LA KHONG DU
  #
  # Organization rule trien khai xuong MOI account trong to chuc, va
  # AWS lam tuan tu. Provider chi cho 5 phut roi bao:
  #
  #   timeout while waiting for state to become 'CREATE_SUCCESSFUL'
  #   (last state: 'CREATE_IN_PROGRESS', timeout: 5m0s)
  #
  # Do KHONG phai that bai - rule van dang duoc tao va thuong xong
  # sau do vai phut. Nhung Terraform ghi vao state o trang thai do
  # va lan apply sau se doi tao lai.
  #
  # Cang nhieu account, cang nhieu rule thi cang lau. Voi 6 account va
  # 8 rule, 30 phut VAN KHONG DU - da do thuc te. AWS trien khai tung
  # rule mot xuong tung account, va 8 rule chay song song deu cham
  # muc 30 phut cung luc.
  ####################################
  timeouts {
    create = "90m"
    update = "90m"
    delete = "90m"
  }

  ####################################
  # THU TU QUAN TRONG: RECORDER TRUOC, RULE SAU
  #
  # Rule danh gia du lieu do recorder ghi. Trien khai rule xuong mot
  # account CHUA CO recorder thi rule khong co gi de doc - no o
  # INSUFFICIENT_DATA, hoac keo dai CREATE_IN_PROGRESS.
  #
  # Truoc day chi phu thuoc aggregator. Aggregator chi GOM du lieu,
  # no khong tao ra du lieu - nen phu thuoc vao no la chua du.
  # StackSet moi la thu dung recorder o tung account.
  ####################################
  depends_on = [
    aws_config_configuration_aggregator.org,
    aws_cloudformation_stack_set_instance.recorder,
  ]
}

########################################
# KIEM TRA CHEO
########################################

check "rules_have_matching_resource_types" {
  assert {
    # Rule kiem tra loai resource ma recorder KHONG ghi thi se mai
    # o trang thai INSUFFICIENT_DATA - khong bao gio bao gi, va rat
    # de nham la "moi thu deu on".
    condition = !local.enabled || alltrue([
      for name, _ in var.organization_rules :
      !startswith(name, "s3-") || contains(var.resource_types, "AWS::S3::Bucket")
    ])

    error_message = "Co rule s3-* nhung resource_types khong ghi AWS::S3::Bucket. Rule se mai o trang thai INSUFFICIENT_DATA - im lang, va de nham la moi thu deu on."
  }
}

########################################
# MANAGEMENT ACCOUNT PHAI NAM TRONG excluded_accounts
#
# Organization rule day xuong ca management account, ma o do Config
# thuong chua bao gio duoc bat nen chua co service-linked role:
#
#   UnableToAssumeServiceLinkedRoleException
#
# Rule se ngoi CREATE_IN_PROGRESS hang chuc phut roi CREATE_FAILED,
# keo ca lan apply theo. Day la truong hop DUY NHAT kiem tu dong
# duoc - cac account khac ngoai recorder_target_ous thi phai tu doi
# chieu, xem mo ta bien excluded_accounts.
########################################

check "management_account_excluded" {
  assert {
    condition = !local.enabled || contains(
      var.excluded_accounts,
      data.aws_caller_identity.current.account_id,
    )

    error_message = join(" ", [
      "Management account (${data.aws_caller_identity.current.account_id})",
      "khong nam trong excluded_accounts. Organization rule se duoc day",
      "xuong do va hong voi UnableToAssumeServiceLinkedRoleException",
      "sau vai chuc phut cho.",
      "Them no vao excluded_accounts - va kiem luon cac account nam",
      "ngoai recorder_target_ous, chung hong voi",
      "NoAvailableConfigurationRecorder.",
    ])
  }
}

check "rule_count_reasonable" {
  assert {
    condition     = length(var.organization_rules) <= 15
    error_message = "Dang bat ${length(var.organization_rules)} rule. Moi rule danh gia deu tinh tien, va qua nhieu canh bao thi khong ai doc. Bat dau tu duoi 10, mo rong khi da xu ly het findings hien co."
  }
}
