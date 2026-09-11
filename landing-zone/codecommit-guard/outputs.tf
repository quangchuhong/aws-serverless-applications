output "approval_rule_template" {
  description = "Ten template va repo da gan. Rong nghia la layer dang tat."
  value = local.enabled ? {
    ten            = aws_codecommit_approval_rule_template.main[0].name
    id             = aws_codecommit_approval_rule_template.main[0].approval_rule_template_id
    repo           = var.repository_name
    nhanh          = local.nhanh_ref
    so_nguoi_duyet = var.so_nguoi_duyet
    pool           = var.pool_duyet
  } : null
}

output "policy_chan_push_arn" {
  description = "ARN managed policy chan push truc tiep. CHUA gan vao ai - xem phai_lam_gi."
  value       = try(aws_iam_policy.chan_push[0].arn, null)
}

########################################
# HEREDOC KHONG DUNG DUOC TRONG BIEU THUC BA NHANH
#
# Dau ket thuc heredoc phai dung MOT MINH tren dong, nen
# `... ? <<-EOT ... EOT : "khac"` la cu phap sai va Terraform bao
# "Unterminated template string" - mot thong bao noi ve chuoi chu khong
# noi ve ternary.
#
# Cach dung: dat heredoc vao mot local roi ternary tren local do. Cung
# khuon voi local.next_steps o ops-pipeline.
########################################

locals {
  huong_dan = <<-EOT

    ═══════════ CHOT DUYET: MOT NUA DA XONG ═══════════

    Approval rule template da gan vao ${var.repository_name}.
    Tu gio moi PR vao ${var.branch_name} can ${var.so_nguoi_duyet} luot duyet.

    NHUNG NO CHUA CHAN GI CA, vi push truc tiep van chay.

    ───────────────────────────────────────────────────
    1. GAN POLICY CHAN PUSH

       ${try(aws_iam_policy.chan_push[0].arn, "(chua tao - enable = false)")}

       Gan vao role/permission set cua NGUOI PHAT TRIEN. KHONG gan vao
       role cua pipeline: pipeline chi DOC repo, no khong push.

       Voi IAM Identity Center thi gan vao permission set, khong gan vao
       role da sinh - role sinh ra se bi ghi de.

    ───────────────────────────────────────────────────
    2. DO, DUNG DOAN - BA PHEP THU

       Ba phep nay phai ra BA ket qua khac nhau. Neu chung ra giong nhau
       thi mot trong hai phan chua chay.

       a) Push truc tiep - PHAI BI TU CHOI
          git push codecommit HEAD:${var.branch_name}
          # mong doi: AccessDeniedException tren GitPush

       b) Mo PR - PHAI THANH CONG, va PR phai co approval rule
          aws codecommit create-pull-request \\
            --title "thu chot duyet" \\
            --targets repositoryName=${var.repository_name},sourceReference=<nhanh-cua-ban>,destinationReference=${var.branch_name} \\
            --region ${var.region}

          aws codecommit get-pull-request --pull-request-id <id> \\
            --query 'pullRequest.approvalRules[].approvalRuleName' --region ${var.region}
          # mong doi: co ten "${local.name}"
          # RONG nghia la template chua gan - khong phai "chua can duyet"

       c) Merge PR khi CHUA du luot duyet - PHAI BI TU CHOI
          aws codecommit merge-pull-request-by-fast-forward \\
            --pull-request-id <id> --repository-name ${var.repository_name} \\
            --region ${var.region}
          # mong doi: PullRequestApprovalRulesNotSatisfiedException

       Phep (c) la phep duy nhat chung minh rang chot duyet co hieu luc.
       (a) va (b) chi chung minh rang no TON TAI.

    ───────────────────────────────────────────────────
    3. NEU (c) THANH CONG - dung lai va doc

       Nghia la merge di qua ma khong can duyet. Hai nguyen nhan hay gap:

         - Nguoi merge co mot policy Allow rong hon ghi de (Deny cua
           layer nay chi chan GitPush/MergeBranches*, khong chan
           MergePullRequest* - xem chu thich trong main.tf).
         - Template gan vao nhanh KHAC nhanh pipeline dang nghe.

    ───────────────────────────────────────────────────
    4. DIEU LAYER NAY KHONG LAM DUOC

       CodeCommit KHONG co CODEOWNERS. Khong the noi "doi bao mat phai
       duyet catalog/scp.yaml, con lai thi khong" - approval rule gan
       theo NHANH, mot con so cho ca nhanh.

       Nen: hoac sec duyet MOI PR (ke ca mot thay doi DNS cua cloudops),
       hoac tach HAI REPO va moi repo mot pool. Xem main.tf muc
       "CODECOMMIT KHONG CO CODEOWNERS".

    ═══════════════════════════════════════════════════

  EOT
}

output "phai_lam_gi" {
  value = local.enabled ? local.huong_dan : "Layer dang TAT (enable = false). Chua co chot duyet nao - push truc tiep vao nhanh chinh van chay."
}
