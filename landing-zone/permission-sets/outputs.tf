output "portal_url" {
  description = <<-EOT
    AWS access portal - noi user dang nhap va chon account.

    Day la URL mac dinh dung identity store ID. Neu ban da dat alias
    tuy chinh trong Identity Center settings thi URL that se la
    https://<alias>.awsapps.com/start
  EOT
  value       = "https://${local.identity_store_id}.awsapps.com/start"
}

output "sso_instance_arn" {
  value = local.sso_instance_arn
}

output "identity_store_id" {
  value = local.identity_store_id
}

output "permission_sets" {
  description = "Ten -> ARN + pham vi + thoi luong phien"
  value = {
    for k, v in local.permission_sets : k => {
      arn              = aws_ssoadmin_permission_set.this[k].arn
      scope            = v.scope
      accounts         = length(local.scope_accounts[v.scope])
      session_duration = v.session_duration
    }
  }
}

output "assignment_count" {
  description = "Tong so assignment = so IAM role Identity Center se tao ra"
  value       = length(local.assignments)
}

output "assignment_matrix" {
  description = <<-EOT
    Ma tran doc duoc: group -> permission set -> so account.

    Doi chieu voi bang thiet ke sau moi lan apply.
  EOT
  value = {
    for gname, g in local.groups : gname => {
      for ps in g.permission_sets :
      ps => length(local.scope_accounts[local.permission_sets[ps].scope])
    }
  }
}

output "accounts_in_scope" {
  description = "So account theo tung pham vi"
  value       = { for k, v in local.scope_accounts : k => length(v) }
}

output "unscoped_accounts" {
  description = <<-EOT
    Account ACTIVE khong thuoc analytics/nonprod/prod nao.

    Cac account nay chi nhan duoc permission set pham vi "all".
    Neu co account workload nam trong danh sach nay thi ban da quen
    khai no vao accounts_by_scope.
  EOT
  value = sort(tolist(setsubtract(
    toset(local.all_accounts),
    toset(flatten(values(var.accounts_by_scope))),
  )))
}

########################################
# Nhac viec sau khi apply
########################################

output "next_steps" {
  value = <<-EOT

    1. User nhan email dat password (chi khi dung Identity Center directory).

    2. BAT MFA BAT BUOC - khong lam duoc bang Terraform:
       Identity Center console -> Settings -> Authentication
       -> Multi-factor authentication -> Require MFA every time

       KHONG dat dieu kien aws:MultiFactorAuthPresent trong policy cua
       permission set: phien Identity Center khong mang claim nay mot
       cach dang tin, them vao se sinh Access Denied kho hieu.

    3. lz-billing can mot cong tac THU CONG o management account:
       Billing console -> Account -> IAM user and role access to
       Billing information -> Activate
       Khong bat thi permission set van bi Access Denied.

    4. Dang nhap CLI:
       aws configure sso
       aws sso login --profile <ten>
       aws sts get-caller-identity --profile <ten>
       -> ARN phai co dang assumed-role/AWSReservedSSO_<set>_<hash>/<user>

    5. Doi chieu output assignment_matrix voi bang thiet ke.

    6. Kiem tra output unscoped_accounts - account workload nam trong
       do la da quen khai pham vi.

  EOT
}
