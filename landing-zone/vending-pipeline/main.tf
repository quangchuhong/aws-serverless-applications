########################################
# SAU STAGE, KHAI THANH DU LIEU
#
# Moi stage la mot dong o day. Them mot stage la them mot dong, khong
# phai chep mot khoi resource - va nho vay khong co chuyen hai stage
# lech nhau vi ai do sua mot cai quen cai kia.
########################################

locals {
  enabled = var.enable

  # Hai stage network chi ton tai khi co role de assume. Khong co thi
  # bon stage con lai van chay - xem mo ta network_deploy_role_arn.
  network_on = var.network_deploy_role_arn != ""

  ####################################
  # THU TU LA MOT PHAN CUA THIET KE
  #
  # A -> B -> C -> D bat buoc theo dung thu tu do:
  #   B can account ID ma A vua tao
  #   C can TGW ma B vua chia se
  #   D can attachment ma C vua tao
  #
  # E va F khong phu thuoc nhau, nhung dat sau D de mot lan chay bao
  # "xong" nghia la moi thu da xong - khong phai "xong phan mang, con
  # phan quyen truy cap thi tuan sau".
  ####################################
  stages_all = [
    {
      key    = "A-tao-account"
      layer  = "landing-zone/account-baseline"
      assume = false
      wait   = false

      ####################################
      # GIOI HAN VAO DUNG VIEC TAO ACCOUNT
      #
      # Stage A va stage C la CUNG mot layer. Khong co dong nay thi
      # `terraform apply` cua stage A tao luon spoke_network - truoc
      # khi stage B kip chia se TGW - va stack o account dich cho mot
      # loi moi RAM chua duoc gui, het gio, rollback.
      #
      # Thu tu sau stage chi co y nghia khi moi stage lam DUNG phan
      # cua no. Truoc ban nay, tai lieu noi "khoi network: khai duoc
      # ngay tu dau vi pipeline giai quyet bang thu tu stage" - cau do
      # sai, vi thu tu stage khong tach duoc hai viec nam trong cung
      # mot `terraform apply`. Xem loi 103 doc 22.
      #
      # catalog_guard khong can liet ke: aws_organizations_account
      # phu thuoc vao no, nen -target keo no theo.
      ####################################
      targets = ["aws_organizations_account.this"]

      mo_ta = "Tao account tu catalog - CHI tao account. Gan nhu khong hoan tac duoc, doc ky email."
    },
    {
      key     = "B-chia-se-tgw"
      layer   = "landing-zone/network"
      assume  = true
      wait    = false
      targets = []
      mo_ta   = "Chia se Transit Gateway cho account vua tao."
    },
    {
      key     = "C-mang-nen"
      layer   = "landing-zone/account-baseline"
      assume  = false
      wait    = false
      targets = []
      mo_ta   = "StackSet dung VPC, subnet, TGW attachment, DNS o account dich."
    },
    {
      key     = "D-noi-route-table"
      layer   = "landing-zone/network"
      assume  = true
      wait    = true # cho attachment sang `available` TRUOC khi plan
      targets = []
      mo_ta   = "Noi attachment vao rtb-spokes va propagate vao rtb-security."
    },
    {
      key     = "E-config-detective"
      layer   = "landing-zone/config-detective"
      assume  = false
      wait    = false
      targets = []
      mo_ta   = "excluded_accounts - account khong co recorder phai duoc loai tru."
    },
    {
      key     = "F-permission-sets"
      layer   = "landing-zone/permission-sets"
      assume  = false
      wait    = false
      targets = []
      mo_ta   = "accounts_by_scope - khong co buoc nay thi khong ai vao duoc account moi."
    },
  ]

  stages = [for s in local.stages_all : s if local.network_on || !s.assume]

  # Khoa state cua tung layer, tra san de buildspec khong phai doan.
  #
  # distinct() la BAT BUOC: stages_all co account-baseline HAI LAN
  # (stage A va C) va network HAI LAN (B va D) - do la ca thiet ke,
  # khong phai nham. Gom truc tiep theo s.layer thi hai stage cung
  # layer sinh trung khoa va Terraform tu choi ca file:
  #
  #   Error: Duplicate object key
  #   Two different items produced the key "landing-zone/network"
  #
  # Tra cuu var.layer_keys[l] chu khong try(): mot layer nam trong
  # stages_all ma thieu o layer_keys phai hong NGAY o day, kem ten
  # khoa - chu khong lang le thanh chuoi rong roi di toi tan
  # `terraform init` voi mot backend khong co key.
  stage_keys = {
    for l in distinct([for s in local.stages_all : s.layer]) :
    l => var.layer_keys[l]
  }

  name = "${var.project}-vending"

  # Toan bo role o account khac ma CodeBuild duoc phep assume.
  #
  # Gom hai nguon: role mang (stage B, D) va role o cac account thanh
  # vien (stage E). distinct() vi hai nguon co the trung neu ai do
  # khai role mang o ca hai cho.
  assume_targets = distinct(compact(concat(
    [local.network_on ? var.network_deploy_role_arn : ""],
    var.member_assume_role_arns,
  )))

  next_steps = <<-EOT

    ═══════════════ SAU KHI APPLY ═══════════════

    1. XAC NHAN DIA CHI NHAN THU
       Moi dia chi trong approval_emails nhan mot thu tu SNS va phai
       BAM XAC NHAN. Truoc do subscription o PendingConfirmation va
       khong nhan gi - Terraform van bao tao thanh cong.

         aws sns list-subscriptions-by-topic --region ${var.region} \
           --topic-arn <arn o output approval_topic_arn> \
           --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table

       SubscriptionArn con la "PendingConfirmation" = chua bam.

    2. DAY CODE LEN CODECOMMIT
       Pipeline doc tu repo "${var.repository_name}", nhanh
       "${var.branch_name}". Repo GitHub KHONG kich hoat gi ca.

    3. LAN CHAY DAU TIEN PHAI LA MOT LAN KHONG CO ACCOUNT MOI
       Moi stage phai ra "KHONG CO THAY DOI". Duyet sau lan de xem
       duong di co thong khong - TRUOC khi mot account that di qua no.
       Mot account tao nham gan nhu khong hoan tac duoc.

    4. DOC PLAN TRUOC KHI DUYET
       Thu duyet KHONG chua noi dung plan, co y: mot cong duyet ma
       noi dung hien ngay trong thu se duoc bam tu dien thoai.
       Mo log CodeBuild cua stage do.

    ═════════════════════════════════════════════

  EOT

  # Layer ma pipeline duoc phep dong toi. Dung cho IAM policy cua
  # CodeBuild: no chi duoc doc/ghi state cua bon layer nay, khong phai
  # ca bucket.
  state_object_arns = [
    for _, k in var.layer_keys :
    "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket}/${k}"
  ]
}

########################################
# KIEM TRA CHEO
########################################

check "co_nguoi_nhan_thu_duyet" {
  assert {
    condition = !local.enabled || length(var.approval_emails) > 0
    error_message = join(" ", [
      "Pipeline bat nhung approval_emails rong.",
      "Cong duyet VAN chan - chi la khong ai duoc bao, va nguoi ta phai tu mo",
      "console ra xem co gi dang cho khong.",
      "Mot pipeline dung im cho duyet ma khong goi ai se bi coi la hong,",
      "va lan sau se co nguoi bam Approve ma khong doc.",
    ])
  }
}

check "hai_stage_mang_co_role" {
  assert {
    condition = !local.enabled || local.network_on
    error_message = join(" ", [
      "network_deploy_role_arn de rong, nen pipeline BO QUA stage B va D.",
      "Buoc 2 (chia se TGW) va buoc 5 (noi attachment vao route table) phai",
      "lam tay theo doc 27 - va bo qua buoc 5 thi VPC ton tai, attachment ton",
      "tai, va khong goi tin nao di dau ca.",
      "Day la mot lua chon hop le, khong phai loi - nhung phai la lua chon.",
    ])
  }
}

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
