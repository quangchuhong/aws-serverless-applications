########################################
# PIPELINE VAN HANH - CAC LAYER DOI HANG NGAY
#
# Chay o ACCOUNT MANAGEMENT, canh vending-pipeline nhung TACH HAN.
#
# --------------------------------------------------------------
# VI SAO KHONG GOP VAO vending-pipeline
#
# Hai pipeline nay doi lap nhau o moi chieu:
#
#                 vending              ops
#   Tan so        khi can account moi  hang ngay
#   Ban kinh      lon nhat (tao        nho, DO THIET KE
#                 account, sua TGW)
#   Cong duyet    bat buoc o stage A   khong nen co
#   Dau vao       catalog + tfvars     catalog (da nam trong git)
#
# Gop lai thi moi lan mo mot port hay them mot Deny se:
#
#   1. Chay stage B va D - layer network, tuc TGW, firewall va moi
#      VPC cua to chuc.
#   2. Dung o cong duyet cua stage A, vi stage do LUON chay.
#
# Dieu thu hai mot minh da du lam pipeline vo dung cho van hanh hang
# ngay: khong ai bam duyet mot thay doi DNS record ba lan mot ngay.
#
# --------------------------------------------------------------
# KHONG CO CONG DUYET, VA DO LA MOT LUA CHON CO LY
#
# Voi vending, thu can doc la BAN PLAN: hau qua (mot account voi email
# vinh vien) khong hien ra trong diff cua catalog.
#
# Voi ops thi nguoc lai - diff cua catalog CHINH LA thay doi:
#
#   + - sid: DenyRdsDeleteProd
#   +   action: ["rds:DeleteDBInstance"]
#   +   ticket: SEC-2291
#
# Ba dong do noi ro hon bat ky ban plan Terraform nao. Nen cho duyet
# dung la PR tren git, khong phai mot cong trong CodeBuild noi nguoi
# ta bam tu dien thoai.
#
# Doi lai, hai lop bu:
#
#   1. FAIL_ON_DESTROY=yes - plan co xoa hoac thay the thi dung ngay o
#      buoc plan, chua apply gi.
#   2. lint cua tung layer chay TRUOC moi stage. Voi SCP, lint phan
#      biet THAT voi NOI va tu choi moi thay doi noi long khong mang
#      khoi `loosen`. Xem organization/lint.sh.
#
# --------------------------------------------------------------
# LAP LAI CODE VOI vending-pipeline - CO Y, TAM THOI
#
# Layer nay khong dung chung module voi vending-pipeline, nen buildspec
# va phan IAM co cho giong nhau. Do la mot khoan no ky thuat CO Y:
#
#   - vending-pipeline dang la duong chay cho phep do mot-luot
#     (app-prod-5). Tach module la sua ca hai cung luc, va sua mot thu
#     dang duoc do la cach chac chan nhat de khong biet ket qua do la
#     cua cai gi.
#
# Sau khi phep do do xong, buoc dung la tach modules/tf-pipeline/ va
# cho ca hai dung chung. Ghi ra day de no khong thanh no im lang.
########################################

locals {
  enabled = var.enable
  name    = "${var.project}-ops"

  ####################################
  # TOPIC BAO DRIFT: TU TAO HAY DUNG SAN
  #
  # drift_topic_arn thang neu khai ca hai - va check
  # "khong_khai_ca_hai_nguon_topic" keu ve dieu do, vi im lang chon mot
  # trong hai nghia la nhung dia chi trong drift_emails khong nhan duoc
  # gi ma khong ai biet.
  ####################################
  tao_topic   = var.drift_topic_arn == "" && length(var.drift_emails) > 0
  drift_topic = var.drift_topic_arn != "" ? var.drift_topic_arn : try(aws_sns_topic.drift[0].arn, "")

  ####################################
  # STAGE, KHAI THANH DU LIEU
  #
  # Them mot layer vao pipeline la them MOT DONG o day.
  #
  # Thu tu trong danh sach la thu tu chay - xem for_each o pipeline.tf.
  # KHONG dua vao ten stage de sap xep: do la loi 113, va no da xay ra
  # mot lan o vending-pipeline.
  ####################################
  stages_all = [
    {
      key   = "A-scp"
      layer = "landing-zone/organization"

      ####################################
      # GIOI HAN VAO DUNG SCP
      #
      # Layer organization quan CA cay OU, delegated administrator va
      # tag policy. Pipeline nay KHONG duoc cham vao chung:
      #
      #   - Cay OU doi vai lan mot nam, va moi lan doi lam moi target
      #     cua SCP phai giai lai. Mot pipeline tu apply viec do la mot
      #     pipeline co the lam ca to chuc khong con SCP nao.
      #   - Delegated administrator la quyen, khong phai cau hinh.
      #
      # -target giu pham vi lai dung hai resource. LUU Y: -target gioi
      # han APPLY, con PLAN van refresh toan bo state - nen role can
      # DOC RONG va GHI HEP. Xem iam.tf.
      ####################################
      targets = [
        "aws_organizations_policy.scp",
        "aws_organizations_policy_attachment.scp",
      ]

      # Lenh lint chay TRUOC plan, trong cung thu muc layer.
      # --aws de bo phan loai THAT/NOI doc duoc policy dang gan that.
      # --strict de canh bao thanh loi trong pipeline.
      lint = "./lint.sh --aws --strict"

      mo_ta = "SCP tu catalog/scp.yaml. That chay tu do, noi phai co khoi loosen."
    },
  ]

  stages = [
    for i, s in local.stages_all : merge(s, { thu_tu = i })
  ]

  # Khoa state cua tung layer. Tra cuu truc tiep chu khong try(): mot
  # layer nam trong stages_all ma thieu o layer_keys phai hong NGAY o
  # day, kem ten khoa - chu khong lang le thanh chuoi rong roi di toi
  # tan `terraform init` voi mot backend khong co key.
  stage_keys = {
    for l in distinct([for s in local.stages_all : s.layer]) :
    l => var.layer_keys[l]
  }

  next_steps = <<-EOT

    ═══════════════ SAU KHI APPLY ═══════════════

    1. DAY tfvars CUA CAC LAYER OPS LEN KHO
       Pipeline doc tfvars tu s3://${var.tfvars_bucket}, KHONG tu git
       (tfvars nam trong .gitignore). Them layer moi thi phai day file
       cua no len, neu khong stage se dung lai voi mot loi ro rang.

         cd ../vending-pipeline && ./push-tfvars.sh

       LUU Y: push-tfvars.sh phai biet ve ${join(", ", keys(local.stage_keys))}.
       Thieu thi khong co loi luc day - chi co loi luc pipeline chay.

    2. DAY CODE LEN CODECOMMIT
       Repo GitHub KHONG kich hoat gi ca.

    3. LAN CHAY DAU TIEN PHAI LA MOT LAN KHONG CO THAY DOI
       Moi stage phai ra "KHONG CO THAY DOI". De xem duong di co thong
       khong TRUOC khi mot thay doi that di qua no.

    4. KHONG CO CONG DUYET - do la co y
       Cho duyet la PR tren git. Doi lai: FAIL_ON_DESTROY=yes, va lint
       cua tung layer chay truoc plan.

    5. DRIFT: mot CodeBuild rieng chay theo lich "${var.drift_cron}"
       No chi `plan -lock=false`, khong bao gio apply. Mot lan chay ra
       KHAC "khong co thay doi" nghia la co nguoi sua tay.

       ${local.drift_topic == "" ? "CHUA khai drift_emails hay drift_topic_arn - khong ai duoc bao." : "Bao ve: ${local.drift_topic}"}

    ═════════════════════════════════════════════

  EOT
}

########################################
# KIEM TRA CHEO
########################################

check "khoa_state_khong_trung" {
  assert {
    condition = length(values(var.layer_keys)) == length(distinct(values(var.layer_keys)))
    error_message = join(" ", [
      "Hai layer dang tro vao CUNG mot khoa state:",
      join(", ", [for k, v in var.layer_keys : "${k} -> ${v}"]),
      ". Hai layer dung chung mot state se giam len nhau, va cai apply sau se",
      "coi resource cua cai truoc la thu can xoa.",
    ])
  }
}

check "moi_stage_co_lint" {
  assert {
    condition = length([for s in local.stages_all : s.key if try(s.lint, "") == ""]) == 0
    error_message = join(" ", [
      "Stage khong co lenh lint:",
      join(", ", [for s in local.stages_all : s.key if try(s.lint, "") == ""]),
      ". Pipeline nay KHONG co cong duyet, nen lint la lop kiem duy nhat chay",
      "truoc khi Terraform cham vao AWS. Mot stage khong lint la mot stage",
      "chi con FAIL_ON_DESTROY - va FAIL_ON_DESTROY khong biet gi ve y nghia",
      "cua thay doi, no chi dem so resource bi xoa.",
    ])
  }
}

check "stage_khong_cham_ngoai_pham_vi" {
  assert {
    condition = length([
      for s in local.stages_all : s.key
      if s.layer == "landing-zone/organization" && length(try(s.targets, [])) == 0
    ]) == 0
    error_message = join(" ", [
      "Stage tro vao layer organization ma KHONG khai targets.",
      "Layer do quan ca cay OU, delegated administrator va tag policy.",
      "Khong gioi han thi pipeline nay apply duoc CA CHUNG - va mot lan doi",
      "cay OU tu dong la mot lan moi target cua SCP phai giai lai, tuc ca to",
      "chuc co the khong con SCP nao gan vao dau.",
    ])
  }
}
