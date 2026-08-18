########################################
# DELEGATED ADMINISTRATOR
#
# Chuyen quyen quan tri mot dich vu pham vi to chuc tu management
# account sang mot account chuyen trach (thuong la security tooling).
#
# VI SAO DAT O LAYER NAY chu khong o config-detective:
# no la thao tac cua Organizations, chi lam duoc TU MANAGEMENT ACCOUNT,
# va no la dieu kien tien quyet - config-detective khong dung noi
# aggregator hay organization rule neu chua co dong nay.
#
# ---------------------------------------------------------------
# CANH BAO: GAN NHU KHONG DAO NGUOC
#
# Moi dich vu chi co MOT delegated admin. Doi sang account khac khi
# da co member dang enable la rat kho - voi GuardDuty thi khong doi
# duoc, phai go het member truoc.
#
# => Chon account MOT LAN, chon dung.
########################################

variable "delegated_administrators" {
  description = <<-EOT
    Service principal -> account ID nhan quyen quan tri.

    De RONG o giai doan dau. Chi dien khi da co account security
    tooling that su ton tai.

    Service principal hay dung:
      config.amazonaws.com              - Config aggregator + organization rule
      config-multiaccountsetup.amazonaws.com
                                        - CAN THEM cai nay moi dung duoc
                                          aws_config_organization_managed_rule
      securityhub.amazonaws.com         - Security Hub admin
      guardduty.amazonaws.com           - GuardDuty admin
      access-analyzer.amazonaws.com     - IAM Access Analyzer
      storage-lens.s3.amazonaws.com

    LUU Y hai dong config: chung la HAI service principal khac nhau
    va deu can. Thieu cai thu hai thi organization rule bao
    AccessDeniedException ma khong noi ro thieu gi - day la loi hay
    mat nhieu thoi gian nhat trong ca layer nay.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for _, id in var.delegated_administrators : can(regex("^[0-9]{12}$", id))
    ])
    error_message = "Account ID phai dung 12 chu so."
  }
}

resource "aws_organizations_delegated_administrator" "this" {
  for_each = var.delegated_administrators

  account_id        = each.value
  service_principal = each.key

  # Go delegated admin khi con member dang enable se loi hoac de lai
  # trang thai nua voi. Xoa co chu dich thi bo dong nay truoc.
  lifecycle {
    prevent_destroy = true
  }
}

########################################
# KIEM TRA CHEO
########################################

check "config_needs_both_service_principals" {
  assert {
    condition = !contains(keys(var.delegated_administrators), "config.amazonaws.com") || contains(
      keys(var.delegated_administrators), "config-multiaccountsetup.amazonaws.com"
    )

    error_message = join(" ", [
      "Da uy quyen config.amazonaws.com nhung thieu",
      "config-multiaccountsetup.amazonaws.com.",
      "Thieu cai thu hai thi aws_config_organization_managed_rule se bao",
      "AccessDeniedException ma khong noi ro nguyen nhan.",
    ])
  }
}

check "delegated_admin_not_management_account" {
  assert {
    condition = alltrue([
      for _, id in var.delegated_administrators : id != data.aws_caller_identity.current.account_id
    ])

    error_message = "Khong uy quyen ve chinh management account - het y nghia cua viec tach quyen, va vai API se tu choi."
  }
}

output "delegated_administrators" {
  description = "Service principal -> account dang giu quyen quan tri"
  value       = { for k, v in var.delegated_administrators : k => v }
}
