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
    # targets doc tu scp_attachments - tuc tu thu THAT SU duoc gan -
    # chu khong tu v.targets, la thu da KHAI.
    #
    # Hai cai do tung lech nhau ma khong ai thay: mot target khong
    # giai duoc thanh OU ID bi loai khoi scp_attachments im lang,
    # trong khi output nay van in ten no ra. Bang tom tat khang dinh
    # mot guardrail dang chay, con thuc te khong co attachment nao.
    for k, v in local.scp_enabled : k => {
      id = aws_organizations_policy.scp[k].id
      targets = var.scp_dry_run ? ["(dry-run: chua gan)"] : [
        for a in local.scp_attachments : "${a.target}" if a.policy == k
      ]
      targets_khai = v.targets
      bytes        = length(format("{\"Version\":\"2012-10-17\",\"Statement\":[%s]}", join(",", v.statements)))
      limit        = 5120
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
  # Giai qua local.ou_scope_ids, thu moi cach viet ten - xem
  # organization.tf. Tra cuu mot chuoi cung o day tung tra ve o TRONG
  # cho mot cay OU hoan toan hop le.
  value = local.ou_scope_ids
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

output "tag_policy" {
  description = "Tag policy: dang chan hay chi bao cao"
  value = {
    enabled = var.enable_tag_policy
    keys    = sort(keys(var.tag_policy_keys))

    # Khoa co enforced_for = dang thuc su tu choi thao tac gan tag sai.
    # Rong nghia la CHI BAO CAO - trang thai khoi dau dung, nhung dung
    # nham la tag da duoc ep buoc.
    enforcing   = sort(local.tp_enforcing)
    report_only = var.enable_tag_policy && length(local.tp_enforcing) == 0

    policy_id = try(aws_organizations_policy.tag[0].id, null)
    targets   = var.tag_policy_targets
  }
}
