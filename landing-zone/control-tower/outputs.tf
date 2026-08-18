output "enabled" {
  description = "Control Tower co dang bat khong"
  value       = local.enabled
}

output "landing_zone_arn" {
  value = one(aws_controltower_landing_zone.this[*].arn)
}

output "landing_zone_version" {
  description = "Phien ban dang chay. Doi var.landing_zone_version roi apply de nang cap."
  value       = one(aws_controltower_landing_zone.this[*].version)
}

output "drift_status" {
  description = <<-EOT
    Control Tower tu phat hien drift khi co thay doi lam ngoai no.

    Drift o day KHAC voi drift cua Terraform: CT so voi baseline cua
    chinh no, khong so voi state Terraform. Hai he thong co the cung
    bao drift vi hai ly do khac nhau.
  EOT
  value       = one(aws_controltower_landing_zone.this[*].drift_status)
}

output "core_accounts" {
  value = {
    log_archive = local.log_archive_id
    audit       = local.audit_id
  }
}

output "controls_enabled" {
  description = "Control dang bat, theo OU"
  value       = { for k, v in local.control_pairs : k => v.control_id }
}

output "cost_drivers" {
  description = <<-EOT
    Nhung thu SINH CHI PHI khi bat Control Tower.

    Con so thuc te phu thuoc so resource va tan suat thay doi -
    kiem bang AWS Pricing Calculator, dung tin uoc luong nao khac.
  EOT
  value = {
    governed_regions   = length(var.governed_regions)
    config_scope       = "${length(var.governed_regions)} region x moi account duoc quan tri"
    log_retention_days = var.log_retention_days
    note               = "AWS Config la khoan lon nhat. Giam governed_regions la cach giam chi phi hieu qua nhat."
  }
}

output "comparison_with_diy" {
  description = "Doi chieu nhanh voi ../organization (ban DIY)"
  value = {
    ou_tree        = local.enabled ? "Control Tower tao Security + Sandbox; OU khac them qua CT" : "(tat) - ban DIY: aws_organizations_organizational_unit"
    guardrails     = local.enabled ? "aws_controltower_control (SCP + Config rule)" : "(tat) - ban DIY: 4 SCP tu viet"
    account_vend   = local.enabled ? "Account Factory / AFT" : "(tat) - ban DIY: doc 09"
    permission_set = "CA HAI ban deu dung duoc landing-zone/permission-sets"
    state_backend  = "CA HAI ban deu dung duoc landing-zone/tf-backend"
    billing        = "CA HAI ban deu dung duoc landing-zone/billing-guard"
  }
}
