########################################
# HAI PHAN, VA MOT PHAN KHONG DU
#
# Day la cai bay lon nhat cua co che nay:
#
#   approval rule template   ap dung cho PULL REQUEST
#   IAM Deny GitPush         chan PUSH TRUC TIEP
#
# Chi lam phan thu nhat thi approval rule la mot LOI KHUYEN, khong phai
# mot phep chan: ai cung van push thang vao main duoc, va PR chi la mot
# duong di TU NGUYEN. Va no tra loi "da bat duyet chua" bang "co" trong
# khi duong that khong bi chan - dung dang khuyet diem da lap muoi lan
# trong du an nay.
#
# Cung khuon voi SNS lien account (loi 82): hai phia phai mo, va mot
# phia mo mot minh thi khong co loi nao ca.
#
# --------------------------------------------------------------
# CODECOMMIT KHONG CO CODEOWNERS - KHONG CO PHAN QUYEN THEO DUONG DAN
#
# Approval rule template gan theo NHANH DICH, va chi co mot con so
# NumberOfApprovalsNeeded cho ca nhanh. Khong co cach nao noi "doi bao
# mat phai duyet catalog/scp.yaml, con lai thi khong".
#
# Nen chi co hai lua chon, va phai chon:
#
#   1. MOT repo, pool = doi bao mat
#      Sec duyet MOI PR vao main, ke ca mot thay doi DNS record cua
#      cloudops. Dung y "sec duyet rule", nhung tao ma sat cho viec hang
#      ngay - dung thu ma cong duyet cua vending-pipeline da chung minh
#      la khong dung duoc.
#
#   2. HAI repo, moi repo mot pool
#      Repo cua sec: landing-zone/organization + catalog + ops-gate.
#      Repo cua cloudops: phan con lai.
#      Ranh gioi duong dan thanh ranh gioi REPO, tuc co phan quyen thuc.
#
#      Cai phai giai them: ops-gate/gate.py duoc CA HAI pipeline goi.
#      Hai ban sao se lech, va ban lech se la ban long hon. Cach dung:
#      gate.py song o repo cua SEC, duoc dong goi len S3 co version, va
#      buildspec cua cloudops tai ve mot VERSION GHIM. Mot nguon, mot
#      chu so huu, va cloudops khong sua duoc chinh sach an ninh.
#
# Layer nay lam duoc ca hai - khai bao repository_name va approval pool
# la bien. Nhung viec CHON la viec cua nguoi van hanh, khong phai cua
# Terraform, nen no khong co mac dinh.
########################################

locals {
  enabled = var.enable
  name    = "${var.project}-duyet-main"

  repo_arn = "arn:${data.aws_partition.current.partition}:codecommit:${var.region}:${data.aws_caller_identity.current.account_id}:${var.repository_name}"

  nhanh_ref = "refs/heads/${var.branch_name}"
}

########################################
# 1. APPROVAL RULE TEMPLATE
#
# `Version` la mot ngay, khong phai so thu tu - AWS chi nhan dung
# "2018-11-08" cho lieu dang nay. Go khac la mot loi noi ve JSON chu
# khong noi ve phien ban.
########################################

resource "aws_codecommit_approval_rule_template" "main" {
  count = local.enabled ? 1 : 0

  name        = local.name
  description = "PR vao ${var.branch_name} can ${var.so_nguoi_duyet} nguoi duyet tu pool da khai"

  content = jsonencode({
    Version               = "2018-11-08"
    DestinationReferences = [local.nhanh_ref]
    Statements = [{
      Type                    = "Approvers"
      NumberOfApprovalsNeeded = var.so_nguoi_duyet
      ApprovalPoolMembers     = var.pool_duyet
    }]
  })
}

resource "aws_codecommit_approval_rule_template_association" "main" {
  count = local.enabled ? 1 : 0

  approval_rule_template_name = aws_codecommit_approval_rule_template.main[0].name
  repository_name             = var.repository_name
}

########################################
# 2. CHAN PUSH TRUC TIEP
#
# KHONG co phan nay thi phan 1 vo nghia.
#
# Day la mot managed policy, KHONG gan san vao ai: gan no vao role nao la
# viec cua nguoi quan IAM/SSO, va gan sai cho co the khoa chinh minh ra
# khoi repo. Xem output `phai_lam_gi`.
#
# ---------------------------------------------------------------
# HAI DIEU KIEN, VA VI SAO CAN CA HAI
#
#   StringEqualsIfExists codecommit:References = refs/heads/main
#       chi chan thao tac nham vao nhanh main
#   Null codecommit:References = "false"
#       BAT BUOC. Khong co no, Deny se ap ca cho nhung thao tac KHONG
#       mang reference nao - va ket qua la chan nhieu hon y dinh theo
#       kieu kho lan ra.
#
# ---------------------------------------------------------------
# KHONG Deny MergePullRequest*
#
# Danh sach duoi day co MergeBranches* (gop TRUC TIEP, khong qua PR)
# nhung KHONG co MergePullRequest*. Neu Deny ca hai thi khong ai merge
# duoc PR nua - tuc bat duyet xong roi chan luon duong duy nhat di qua
# duoc no.
#
# PHEP KIEM: khong tin dong chu thich nay. Sau khi gan policy, thu DU CA
# HAI - xem output `phai_lam_gi`. Mot bo doi mot lan lam duoc va mot lan
# khong lam duoc la bang chung; mot dong chu thich thi khong.
########################################

data "aws_iam_policy_document" "chan_push" {
  statement {
    sid    = "ChanPushTrucTiepVaoNhanhChinh"
    effect = "Deny"

    actions = [
      "codecommit:GitPush",
      "codecommit:DeleteBranch",
      "codecommit:PutFile",
      "codecommit:MergeBranchesByFastForward",
      "codecommit:MergeBranchesBySquash",
      "codecommit:MergeBranchesByThreeWay",
    ]

    resources = [local.repo_arn]

    condition {
      test     = "StringEqualsIfExists"
      variable = "codecommit:References"
      values   = [local.nhanh_ref]
    }

    condition {
      test     = "Null"
      variable = "codecommit:References"
      values   = ["false"]
    }
  }
}

resource "aws_iam_policy" "chan_push" {
  count = local.enabled ? 1 : 0

  name        = "${local.name}-chan-push"
  description = "Chan push truc tiep vao ${var.branch_name}. Gan vao role cua nguoi phat trien - xem output phai_lam_gi."
  policy      = data.aws_iam_policy_document.chan_push.json
}

########################################
# KIEM TRA CHEO
########################################

check "pool_duyet_khong_rong" {
  assert {
    condition = !local.enabled || length(var.pool_duyet) > 0
    error_message = join(" ", [
      "enable = true nhung pool_duyet RONG.",
      "Mot approval rule voi pool rong khong the duoc thoa man, nen moi PR se",
      "khong bao gio merge duoc - va thong bao cua CodeCommit noi ve so luot",
      "duyet con thieu, khong noi rang pool khong co ai.",
    ])
  }
}

check "so_nguoi_duyet_khong_vuot_pool" {
  assert {
    condition = !local.enabled || var.so_nguoi_duyet <= length(var.pool_duyet)
    error_message = join(" ", [
      "so_nguoi_duyet =", tostring(var.so_nguoi_duyet),
      "nhung pool_duyet chi co", tostring(length(var.pool_duyet)), "muc.",
      "PR se khong bao gio du luot duyet. LUU Y: mot muc trong pool co the la",
      "mot mau co dau * trum nhieu nguoi, nen phep kiem nay chi bat truong hop",
      "hien nhien - no KHONG chung minh rang pool du nguoi.",
    ])
  }
}
