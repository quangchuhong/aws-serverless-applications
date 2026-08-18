locals {
  enabled = var.enable_landing_zone

  # Tao account loi chi khi vua bat CT vua yeu cau tao
  make_accounts = local.enabled && var.create_core_accounts

  log_archive_id = var.create_core_accounts ? one(aws_organizations_account.log_archive[*].id) : var.log_archive_account_id
  audit_id       = var.create_core_accounts ? one(aws_organizations_account.audit[*].id) : var.audit_account_id
}

########################################
# 1. Hai account loi
#
# aws_controltower_landing_zone doi ACCOUNT ID CO SAN trong manifest.
# No khong tu tao Log Archive va Audit - phai tao truoc.
#
# LUU Y: account KHONG XOA DUOC bang terraform destroy. Terraform chi
# go no khoi state va tach khoi organization. Muon dong that thi phai
# dang nhap root cua account do va dong bang tay, cho 90 ngay.
########################################

resource "aws_organizations_account" "log_archive" {
  count = local.make_accounts ? 1 : 0

  name  = "${var.project}-log-archive"
  email = var.core_account_emails.log_archive

  # Giu account lai khi go khoi Terraform, thay vi tach khoi org
  close_on_deletion = false

  # Doi email hay ten sau khi tao deu khong lam qua Terraform duoc
  lifecycle {
    ignore_changes  = [role_name, iam_user_access_to_billing]
    prevent_destroy = true
  }
}

resource "aws_organizations_account" "audit" {
  count = local.make_accounts ? 1 : 0

  name              = "${var.project}-audit"
  email             = var.core_account_emails.audit
  close_on_deletion = false

  lifecycle {
    ignore_changes  = [role_name, iam_user_access_to_billing]
    prevent_destroy = true
  }
}

########################################
# 2. Landing zone
#
# Manifest la noi khai TOAN BO cau hinh. Doi mot truong o day roi
# apply = Control Tower chay lai quy trinh cap nhat, mat hang chuc
# phut den vai gio.
########################################

resource "aws_controltower_landing_zone" "this" {
  count = local.enabled ? 1 : 0

  version = var.landing_zone_version

  manifest_json = jsonencode({
    governedRegions = var.governed_regions

    organizationStructure = {
      security = { name = var.security_ou_name }
      sandbox  = { name = var.sandbox_ou_name }
    }

    centralizedLogging = {
      accountId = local.log_archive_id
      enabled   = true
      configurations = {
        loggingBucket       = { retentionDays = var.log_retention_days }
        accessLoggingBucket = { retentionDays = var.access_log_retention_days }
      }
    }

    securityRoles = {
      accountId = local.audit_id
    }

    accessManagement = {
      enabled = var.enable_access_management
    }
  })

  tags = local.common_tags

  depends_on = [
    aws_organizations_account.log_archive,
    aws_organizations_account.audit,
  ]
}

########################################
# 3. Controls (guardrails)
#
# Mot control = mot cap (OU, control identifier).
#
# Control Tower cai dat control bang SCP va/hoac AWS Config rule.
# Loai dua tren Config la loai SINH CHI PHI - moi rule danh gia moi
# lan resource doi.
########################################

locals {
  control_pairs = local.enabled ? {
    for item in flatten([
      for ou_name, ids in var.controls : [
        for control_id in ids : {
          key        = "${ou_name}|${control_id}"
          ou_name    = ou_name
          control_id = control_id
          target_arn = try(var.control_target_ou_arns[ou_name], null)
        }
      ]
    ]) : item.key => item if item.target_arn != null
  } : {}
}

resource "aws_controltower_control" "this" {
  for_each = local.control_pairs

  control_identifier = "arn:${data.aws_partition.current.partition}:controltower:${var.region}::control/${each.value.control_id}"
  target_identifier  = each.value.target_arn

  depends_on = [aws_controltower_landing_zone.this]
}

########################################
# KIEM TRA CHEO
########################################

check "core_account_emails_present" {
  assert {
    condition = !local.make_accounts || (
      var.core_account_emails.log_archive != "" &&
      var.core_account_emails.audit != ""
    )
    error_message = "create_core_accounts = true nhung chua dien core_account_emails. Email phai duy nhat toan cau va la email that."
  }
}

check "core_account_ids_present_when_not_creating" {
  assert {
    condition = !local.enabled || var.create_core_accounts || (
      var.log_archive_account_id != "" && var.audit_account_id != ""
    )
    error_message = "create_core_accounts = false thi phai dien log_archive_account_id va audit_account_id."
  }
}

check "controls_have_target_arns" {
  assert {
    condition = length(setsubtract(
      toset(keys(var.controls)),
      toset(keys(var.control_target_ou_arns)),
    )) == 0

    error_message = format(
      "OU khai trong controls nhung thieu ARN trong control_target_ou_arns: %s. Lay bang: aws organizations list-organizational-units-for-parent --parent-id <root-id>",
      join(", ", tolist(setsubtract(
        toset(keys(var.controls)),
        toset(keys(var.control_target_ou_arns)),
      )))
    )
  }
}

check "governed_regions_cost_warning" {
  assert {
    condition     = length(var.governed_regions) <= 2
    error_message = "governed_regions dang co ${length(var.governed_regions)} region. AWS Config chay o MOI account x MOI region - moi region them vao nhan chi phi len theo so account. Chac chan can tung ay chua?"
  }
}
