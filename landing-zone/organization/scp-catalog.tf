########################################
# SCP - DOC TU CATALOG
#
# Statement khong con gõ cứng trong scp.tf. Chung nam o
# catalog/scp.yaml, va file nay bien chung thanh local.scp_definitions
# - dung hinh dang ma phan con lai cua scp.tf da dung tu truoc.
#
# Vi sao tach catalog ra:
#
#   1. Diff doc duoc. Mot PR them mot Deny la bon dong YAML, khong
#      phai mot khoi jsonencode long trong merge long trong locals.
#   2. Moi statement mang duoc metadata - reason, ticket, locked,
#      loosen - thu khong dat vao mot policy document AWS duoc.
#   3. lint.sh kiem duoc TRUOC khi goi AWS: sid trung, do dai vuot
#      5120, OU khong duoc phu, va quan trong nhat la phan biet
#      THAT voi NOI.
#
# TIEU CHI NGHIEM THU CUA BUOC CATALOG HOA: `terraform plan` ra
# 0 changes. Day la refactor thuan. JSON render ra khac mot byte
# nghia la mot guardrail vua bi doi trong luc ta tuong dang don code.
########################################

locals {
  ####################################
  # DUONG MIEN TRU DUNG CHUNG
  #
  # Rong thi khong sinh Condition nao ca - "ArnNotLike" voi mang rong
  # la JSON hop le nhung y nghia mo ho.
  ####################################
  exempt_arns = [
    for r in var.scp_exempt_role_names :
    "arn:${local.partition}:iam::*:role/${r}"
  ]

  has_exempt = length(local.exempt_arns) > 0

  exempt_condition = local.has_exempt ? {
    ArnNotLike = { "aws:PrincipalArn" = local.exempt_arns }
  } : null

  network_exempt_condition = var.network_account_id != "" ? {
    StringNotEquals = { "aws:PrincipalAccount" = var.network_account_id }
  } : null

  ####################################
  # BO SINH CONDITION - CATALOG CHI DUOC GOI TEN
  #
  # Them mot Condition vao mot Deny la cach NOI guardrail tinh vi
  # nhat: khong xoa gi, khong thu hep gi, diff trong nhu "them mot
  # dong". Nen catalog KHONG duoc khai Condition tu do; no chi goi
  # ten mot muc trong bang nay, va bang nay di qua review code.
  #
  # VI SAO LA CHUOI JSON CHU KHONG PHAI OBJECT
  #
  # HCL tu choi index DONG vao mot object co cac thuoc tinh khac kieu
  # nhau - ma sau muc duoi day chinh la khac kieu (cai thi
  # ArnNotLike, cai thi StringLike, cai thi rong). Mot bang toan
  # CHUOI thi dong kieu, nen local.scp_condition_json[ten] chay duoc.
  #
  # jsondecode roi jsonencode lai giu nguyen byte voi du lieu o day
  # (chi co chuoi va mang chuoi), nen phep vong nay khong doi output.
  #
  # "" = KHONG sinh Condition. Khong phai "Condition rong".
  ####################################
  scp_condition_json = {
    none = ""

    exempt_roles = local.has_exempt ? jsonencode(local.exempt_condition) : ""

    root_user_only = jsonencode({
      StringLike = { "aws:PrincipalArn" = "arn:${local.partition}:iam::*:root" }
    })

    # Rong thi KHONG sinh Condition - va luc do khong ai bat duoc
    # public access block, ke ca lop hardening sinh ra de bat. Xem
    # check "s3_pab_co_the_bat_duoc".
    s3_pab_automation = length(var.s3_pab_automation_roles) > 0 ? jsonencode({
      ArnNotLike = {
        "aws:PrincipalArn" = [
          for n in var.s3_pab_automation_roles :
          "arn:${local.partition}:iam::*:role/${n}"
        ]
      }
    }) : ""

    region_lock = jsonencode(merge(
      { StringNotEquals = { "aws:RequestedRegion" = var.allowed_regions } },
      local.has_exempt ? local.exempt_condition : {},
    ))

    network_account_exempt = var.network_account_id != "" ? jsonencode(local.network_exempt_condition) : ""

    public_ip_on_launch = jsonencode({
      Bool = { "ec2:AssociatePublicIpAddress" = "true" }
    })
  }

  ####################################
  # CATALOG -> POLICY DOCUMENT
  ####################################
  scp_raw = yamldecode(file("${path.module}/catalog/scp.yaml"))

  # Phang ra de lint va cac check ben duoi doc duoc tung statement
  # kem policy chua no.
  scp_statements_flat = flatten([
    for p in local.scp_raw.policies : [
      for s in p.statements : merge(s, { policy = p.name })
    ]
  ])

  # Ten condition catalog goi ma bang tren khong co. De day thanh mot
  # LOI ro rang: neu khong, local.scp_condition_json[ten] chet voi
  # "Invalid index" - mot cau khong nhac gi toi catalog.
  scp_condition_unknown = distinct([
    for s in local.scp_statements_flat :
    s.condition if try(s.condition, null) != null && !contains(keys(local.scp_condition_json), try(s.condition, ""))
  ])

  ####################################
  # GIU NGUYEN VO HUONG HAY MANG
  #
  # jsonencode("*") ra `"*"`, jsonencode(["*"]) ra `["*"]`. Hai chuoi
  # JSON khac nhau -> policy document khac nhau -> Terraform thay mot
  # thay doi. Nen khong duoc chuan hoa ve mang "cho gon".
  #
  # try(tostring(x), null) chi thanh cong voi nguyen thuy, nen no la
  # phep thu "day la chuoi hay mang".
  ####################################
  scp_stmt_rendered = {
    for p in local.scp_raw.policies : p.name => [
      for s in p.statements : jsonencode(merge(
        {
          Sid    = s.sid
          Effect = s.effect

          Resource = try(tostring(s.resource), null) != null ? replace(s.resource, "$${partition}", local.partition) : [
            for r in s.resource : replace(r, "$${partition}", local.partition)
          ]
        },

        # Action va NotAction loai tru nhau. lint.sh chan viec khai ca
        # hai hoac khong khai cai nao.
        try(s.action, null) != null ? { Action = s.action } : {},
        try(s.not_action, null) != null ? { NotAction = s.not_action } : {},

        local.scp_condition_json[try(s.condition, "none")] != "" ? {
          Condition = jsondecode(local.scp_condition_json[try(s.condition, "none")])
        } : {},
      ))
    ]
  }

  ####################################
  # HINH DANG MA PHAN CON LAI CUA scp.tf DANG DUNG
  #
  # enabled lay CA HAI nguon: var.enable_scp (de tat nhanh khi dang
  # trien khai tung cai mot) VA truong enabled trong catalog. Mot
  # trong hai noi false thi tat - khong co cach nao bat mot policy da
  # bi tat o nguon kia.
  #
  # try() quanh var.enable_scp[...]: catalog them policy moi ma bien
  # do chua co truong tuong ung thi mac dinh la BAT, khong phai hong.
  ####################################
  scp_definitions = {
    for p in local.scp_raw.policies : p.name => {
      enabled     = try(var.enable_scp[p.name], true) && try(p.enabled, true)
      description = p.description
      statements  = local.scp_stmt_rendered[p.name]
      targets     = p.targets
    }
  }
}

########################################
# KIEM TRA CHEO
#
# lint.sh lam phan lon viec nay truoc khi goi AWS. Cac check duoi day
# la lop thu hai, cho truong hop ai do chay terraform truc tiep.
########################################

check "scp_catalog_condition_co_that" {
  assert {
    condition = length(local.scp_condition_unknown) == 0
    error_message = join(" ", [
      "catalog/scp.yaml goi condition khong co trong bang scp_condition_json:",
      join(", ", local.scp_condition_unknown),
      ". Condition KHONG khai tu do duoc trong catalog - do la co y, vi them",
      "mot Condition vao mot Deny la cach noi guardrail tinh vi nhat.",
      "Can mot condition moi thi them mot muc vao scp_condition_json o",
      "scp-catalog.tf, qua review.",
      "Ten hop le:", join(", ", sort(keys(local.scp_condition_json))),
    ])
  }
}

check "scp_catalog_sid_khong_trung" {
  assert {
    condition = length(local.scp_statements_flat) == length(distinct([for s in local.scp_statements_flat : s.sid]))
    error_message = join(" ", [
      "catalog/scp.yaml co sid trung. AWS khong tu choi dieu nay - no",
      "chi lam mot statement bi ghi de im lang boi statement cung sid,",
      "nen mot guardrail bien mat ma khong co loi nao.",
      "Sid dang co:",
      join(", ", sort([for s in local.scp_statements_flat : s.sid])),
    ])
  }
}

check "scp_catalog_moi_statement_co_reason" {
  assert {
    condition = length([
      for s in local.scp_statements_flat : s.sid
      if try(s.reason, "") == ""
    ]) == 0
    error_message = join(" ", [
      "Statement thieu truong `reason`:",
      join(", ", [for s in local.scp_statements_flat : s.sid if try(s.reason, "") == ""]),
      ". `reason` khong phai thu tuc giay to: no la thu nguoi doc ba nam sau",
      "can de biet co duoc go statement nay hay khong. Danh sach action thi",
      "ho doc duoc tu chinh statement; LY DO thi khong.",
    ])
  }
}
