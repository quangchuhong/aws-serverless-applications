output "organization_id" {
  value = local.org_id
}

output "root_id" {
  value = local.root_id
}

output "ou_ids" {
  description = "Ten OU -> ID. Cap 2 dung duong dan: \"Workloads/Production\""
  value       = local.ou_ids
}

output "scp_summary" {
  description = "SCP nao dang bat, gan vao dau, dai bao nhieu ky tu"
  value = {
    for k, v in local.scp_enabled : k => {
      id      = aws_organizations_policy.scp[k].id
      targets = var.scp_dry_run ? ["(dry-run: chua gan)"] : v.targets
      bytes   = length(format("{\"Version\":\"2012-10-17\",\"Statement\":[%s]}", join(",", v.statements)))
      limit   = 5120
    }
  }
}

output "active_accounts" {
  description = <<-EOT
    Account dang ACTIVE trong organization.

    Dung de doi chieu voi accounts_by_scope cua permission-sets:
    account nao co o day ma khong co ben do thi chi nhan duoc cac
    permission set pham vi "all".
  EOT
  value       = sort(local.active_accounts)
}

output "accounts_by_scope_hint" {
  description = <<-EOT
    Goi y gia tri cho landing-zone/permission-sets.

    OU khong tu chuyen thanh assignment duoc - Identity Center chi
    nhan AWS_ACCOUNT. Sau khi chuyen account vao OU, chay:

      aws organizations list-accounts-for-parent --parent-id <ou-id>

    roi dien vao accounts_by_scope cua permission-sets.
  EOT
  value = {
    analytics = try(local.ou_ids["Data Analytics"], "")
    nonprod   = try(local.ou_ids["Workloads/Non-Production"], "")
    prod      = try(local.ou_ids["Workloads/Production"], "")
  }
}

output "next_steps" {
  value = <<-EOT

    1. KIEM CHUNG SCP TRUOC KHI TIN.

       SCP chan sai thi IM LANG cho toi khi co nguoi vuong. Thu tay:

         # Trong mot account Workloads - phai bi tu choi
         aws ec2 create-internet-gateway --profile <workload>

         # Ngoai allowed_regions - phai bi tu choi
         aws ec2 describe-vpcs --region eu-west-1 --profile <workload>

         # Trong account Infrastructure - phai THANH CONG
         aws ec2 create-internet-gateway --profile <network>

    2. CHUYEN ACCOUNT VAO OU.

         aws organizations move-account \
           --account-id <id> \
           --source-parent-id ${local.root_id} \
           --destination-parent-id <ou-id>

    3. CAP NHAT permission-sets.

       Lay danh sach account trong tung OU roi dien vao
       accounts_by_scope. Bo qua buoc nay = account moi khong ai
       vao duoc, va nguoi ta se quay ra dung root.

    4. SCP KHONG AP DUNG CHO MANAGEMENT ACCOUNT.

       Moi quyen o do la quyen that, khong co tran chan. Do la ly do
       management account phai "sach" - khong chay workload.

  EOT
}

########################################
# SUSPENDED
#
# park-account.sh doc output nay. No tra ve ID cua OU VA trang thai
# dong bang - vi OU ton tai ma khong co SCP la truong hop nguy hiem
# nhat: script chay tron, bao thanh cong, account van chay.
########################################

output "suspended" {
  description = "OU Suspended: id, va SCP dong bang da thuc su gan chua"
  value = {
    ou_id = try(local.ou_ids["Suspended"], null)

    # Gan THAT SU, khong phai "da khai bao". scp_dry_run = true thi
    # policy duoc tao nhung khong gan vao dau - va o day ra false.
    frozen = contains(keys(local.scp_attachments), "suspended|Suspended")

    policy_id = try(aws_organizations_policy.scp["suspended"].id, null)
  }
}
