########################################
# SCP
#
# HAI GIOI HAN CUA AWS quyet dinh cach file nay duoc viet:
#
#   1. Toi da 5 policy gan vao MOT root/OU/account.
#      FullAWSAccess da chiem 1 -> con 4.
#      => Khong viet 10 SCP nho, phai gom thanh vai SCP lon.
#
#   2. Moi SCP toi da 5120 ky tu.
#      => jsonencode (khong xuong dong) chu khong phai file JSON
#         dinh dang dep. Chay ./validate-scp.sh de do.
#
# NHAC LAI: SCP la TRAN QUYEN, khong cap quyen. Mot action chay duoc
# chi khi CA permission set LAN SCP cho phep. Va SCP KHONG ap dung
# cho management account.
########################################

locals {
  ####################################
  # STATEMENT NAM O catalog/scp.yaml
  #
  # Khoi nay truoc day dai ~340 dong: nam local stmt_* chua 13
  # statement duoi dang jsonencode long trong merge, cong
  # scp_definitions gom chung lai.
  #
  # Chung da chuyen sang catalog/scp.yaml va scp-catalog.tf. Ly do
  # khong phai cho gon: mot statement can mang theo reason, ticket,
  # locked va loosen - thu khong dat vao mot policy document AWS
  # duoc, ma lai la thu quyet dinh mot PR co duoc merge hay khong.
  #
  # local.scp_definitions van dung HINH DANG cu, nen moi thu tu day
  # tro xuong - giai target, attachment, resource, check - khong doi
  # mot dong.
  ####################################

  scp_enabled = { for k, v in local.scp_definitions : k => v if v.enabled }

  ########################################
  # GIAI TEN TARGET THANH OU ID
  #
  # Target o tren viet theo duong dan: "Workloads/Production". Do la
  # cach local.ou_ids danh khoa KHI ou_structure khai Production la OU
  # con cua Workloads.
  #
  # Nhung ou_structure la mot BIEN. Khai phang - Production nam thang
  # duoi root - thi khoa la "Production", va "Workloads/Production"
  # khong ton tai.
  #
  # Nen thu ca hai: duong dan day du truoc, roi doan cuoi.
  ########################################
  scp_target_id = {
    for t in distinct(flatten([for _, d in local.scp_enabled : d.targets])) :
    t => t == "ROOT" ? local.root_id : try(
      local.ou_ids[t],
      local.ou_ids[element(split("/", t), length(split("/", t)) - 1)],
      null
    )
  }

  scp_targets_unresolved = [for t, id in local.scp_target_id : t if id == null]

  # (policy, target) -> mot attachment
  scp_attachments = var.scp_dry_run ? {} : {
    for item in flatten([
      for name, def in local.scp_enabled : [
        for t in def.targets : {
          key    = "${name}|${t}"
          policy = name
          ten    = t
          target = local.scp_target_id[t]
        }
      ]
    ]) : item.key => item if item.target != null
  }

  # Chinh sach BAT nhung khong gan duoc vao dau.
  #
  # Dieu nay xay ra IM LANG: `if item.target != null` loai muc do khoi
  # map, khong con dau vet. aws_organizations_policy van duoc tao,
  # console van thay chinh sach, va scp_summary truoc day van in ra
  # danh sach target NHU DA KHAI - trong khi khong co attachment nao.
  #
  # CHUA XAY RA tren trien khai nay. Khoi chan nay duoc them sau mot
  # chan doan SAI: doc nham mot ban in ou_ids thanh cay phang roi ket
  # luan prod_guard khong gan vao dau. Hoi thang AWS thi no dang gan:
  #
  #   aws organizations list-policies-for-target --target-id <ou-id> \
  #     --filter SERVICE_CONTROL_POLICY --query 'Policies[].Name'
  #
  # Giu lai vi co che im lang la co that, va vi ou_structure la mot
  # bien: doi cay thi moi target viet theo duong dan deu truot.
  scp_policies_orphan = var.scp_dry_run ? [] : [
    for name, def in local.scp_enabled : name
    if length([for t in def.targets : t if local.scp_target_id[t] != null]) == 0
  ]
}

########################################
# RESOURCE
########################################

resource "aws_organizations_policy" "scp" {
  for_each = local.scp_enabled

  name        = "${var.project}-${replace(each.key, "_", "-")}"
  description = each.value.description
  type        = "SERVICE_CONTROL_POLICY"

  content = format(
    "{\"Version\":\"2012-10-17\",\"Statement\":[%s]}",
    join(",", each.value.statements)
  )
}

resource "aws_organizations_policy_attachment" "scp" {
  for_each = local.scp_attachments

  policy_id = aws_organizations_policy.scp[each.value.policy].id
  target_id = each.value.target
}

########################################
# CHOT: KHONG CHO MOT SCP TON TAI MA KHONG GAN VAO DAU
#
# precondition chu khong phai check. Mot chinh sach khong gan vao dau
# khong phai "nen xem lai" - no la mot guardrail mo tren giay va
# khong ton tai trong thuc te, va moi thu khac deu bao rang no co.
########################################
resource "terraform_data" "scp_guard" {
  input = {
    orphan     = local.scp_policies_orphan
    unresolved = local.scp_targets_unresolved
  }

  lifecycle {
    precondition {
      condition = length(local.scp_policies_orphan) == 0
      error_message = join(" ", [
        "SCP dang BAT nhung khong gan duoc vao OU nao:",
        join(", ", local.scp_policies_orphan),
        "- chinh sach van duoc tao, console van thay no, va khong co gi bi chan.",
        "Target khong giai duoc:", join(", ", local.scp_targets_unresolved),
        ". Ten OU co that:", join(", ", sort(keys(local.ou_ids))),
        ". Sua targets trong scp_definitions cho khop var.ou_structure,",
        "hoac doi ou_structure cho khop targets.",
      ])
    }

    # Target hong le - chinh sach van con target khac nen khong thanh
    # mo coi. Van phai noi: mot OU dang le duoc bao ve thi khong.
    precondition {
      condition = length(local.scp_targets_unresolved) == 0
      error_message = join(" ", [
        "Target cua SCP khong giai duoc thanh OU ID:",
        join(", ", local.scp_targets_unresolved),
        ". OU do KHONG duoc chinh sach nao gan vao, va viec do khong",
        "hien ra o bat cu dau: aws_organizations_policy van duoc tao,",
        "scp_summary van in ten target nhu da khai.",
        "Ten OU co that:", join(", ", sort(keys(local.ou_ids))),
      ])
    }
  }
}

########################################
# KHONG CO check "moi OU deu co SCP gan truc tiep"
#
# Da tung co mot check nhu vay o day. No SAI VE NGUYEN LY va da bi go.
#
# SCP DI TRUYEN XUONG. Mot chinh sach gan o "Workloads" ap dung cho
# "Workloads/Production" va moi account ben trong. Nen "khong co
# attachment truc tiep" khong noi len dieu gi - va check do keu ten
# Workloads/Non-Production, mot OU dang duoc network_lock phu day du
# qua OU cha.
#
# Con chieu nguoc lai thi cau hoi vo nghia: baseline va region_lock
# gan o ROOT, nen KHONG OU NAO co the "khong duoc chinh sach nao phu".
# Mot phep kiem luon dung khong phai mot phep kiem.
#
# Thu dang kiem la HAI dieu cu the ben duoi - target khong giai duoc,
# va chinh sach khong con target nao - ca hai deu la precondition va
# ca hai deu noi ve mot loi that.
#
# Bai hoc rieng cua khoi nay: mot canh bao keu ten mot thu KHONG SAI
# la cach chac chan nhat de nguoi ta thoi doc canh bao. Chinh repo nay
# viet dieu do trong wire-backends.sh, roi lai vi pham no ngay day.
########################################

########################################
# CAM MOT API DUNG CHO CA BAT LAN TAT = KHONG AI BAT DUOC
########################################
check "s3_pab_co_the_bat_duoc" {
  assert {
    condition = (
      !try(var.enable_scp.baseline, true)
      || length(var.s3_pab_automation_roles) > 0
    )

    error_message = join(" ", [
      "SCP baseline dang cam s3:PutAccountPublicAccessBlock cho MOI principal,",
      "va s3_pab_automation_roles de rong.",
      "Do la MOT API cho ca bat lan tat, nen khong ai - ke ca lop hardening cua",
      "account-baseline - bat duoc account-level public access block.",
      "Setting se KHONG BAO GIO duoc dat, va SCP dang canh mot can phong trong.",
      "Dau hieu duy nhat la 's3/pab:SKIP' trong SweepResult cua tung account:",
      "cd ../account-baseline && ./check-sweep.sh",
      "Sua: dien ten role Lambda quet (mac dinh '<project>-default-vpc-sweep')",
      "vao s3_pab_automation_roles, hoac tat han statement neu ban chon phat hien",
      "thay vi ngan chan.",
    ])
  }
}

########################################
# KIEM TRA GIOI HAN
########################################

check "scp_size_under_limit" {
  assert {
    condition = alltrue([
      for k, v in local.scp_enabled :
      length(format("{\"Version\":\"2012-10-17\",\"Statement\":[%s]}", join(",", v.statements))) <= 5120
    ])

    error_message = format(
      "SCP vuot 5120 ky tu: %s",
      join(", ", [
        for k, v in local.scp_enabled :
        "${k}=${length(format("{\"Version\":\"2012-10-17\",\"Statement\":[%s]}", join(",", v.statements)))}"
        if length(format("{\"Version\":\"2012-10-17\",\"Statement\":[%s]}", join(",", v.statements))) > 5120
      ])
    )
  }
}

check "scp_count_per_target_under_limit" {
  assert {
    # FullAWSAccess luon chiem 1 slot -> toi da 4 SCP tu viet
    condition = alltrue([
      for target in distinct([for _, a in local.scp_attachments : a.target]) :
      length([for _, a in local.scp_attachments : a if a.target == target]) <= 4
    ])

    error_message = "Mot target dang co qua 4 SCP tu viet. AWS gioi han 5 policy/target, FullAWSAccess chiem 1."
  }
}

########################################
# SUSPENDED - hai cach hong LANG LE
#
# Ca hai deu de OU Suspended ton tai ma KHONG dong bang gi ca. Nguy
# hiem hon la khong co OU: park-account.sh chay tron, bao thanh cong,
# va account van chay binh thuong trong mot OU ten "Suspended".
########################################

check "suspended_ou_is_actually_frozen" {
  assert {
    condition = (
      !contains(keys(var.ou_structure), "Suspended")
      || try(var.enable_scp.suspended, true)
    )

    error_message = join(" ", [
      "ou_structure co OU 'Suspended' nhung enable_scp.suspended = false.",
      "OU do se KHONG dong bang gi ca - account chuyen vao van chay",
      "binh thuong, va ten OU lam moi nguoi tuong nguoc lai.",
      "Bat enable_scp.suspended, hoac bo OU 'Suspended' khoi ou_structure.",
    ])
  }
}

check "suspended_not_silently_unattached" {
  assert {
    condition = (
      !contains(keys(var.ou_structure), "Suspended")
      || !try(var.enable_scp.suspended, true)
      || !var.scp_dry_run
    )

    error_message = join(" ", [
      "scp_dry_run = true nen SCP suspended duoc TAO nhung KHONG GAN",
      "vao OU nao. Account park vao Suspended luc nay van chay binh thuong.",
      "Tat scp_dry_run truoc khi dung park-account.sh.",
    ])
  }
}
