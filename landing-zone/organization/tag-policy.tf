########################################
# TAG POLICY
#
# Lap day khoang trong giua "quy uoc" va "rang buoc".
#
# default_tags cua provider gan tag dung o MOI thu Terraform quan ly.
# Nhung ai tao resource bang console, CDK hay SDK thi khong co gi bat
# ho gan - va resource do roi vao cot "chua gan" trong Cost Explorer
# ma khong ai duoc bao.
#
# ---------------------------------------------------------------
# DIEU HAY BI HIEU NHAM NHAT VE TAG POLICY
#
# No KHONG lam cho tag tro thanh BAT BUOC.
#
# Tag policy chi quan ly GIA TRI cua mot tag KHI tag do duoc gan.
# Tao mot EC2 instance khong co tag nao ca thi tag policy khong noi
# gi het - ke ca khi da bat enforced_for.
#
# Ba tang, ba viec khac nhau:
#
#   tag policy         ep DUNG CACH VIET va GIA TRI hop le
#   SCP                chan TAO resource khi thieu tag  (doc 11 muc 5)
#   Config required-tags   PHAT HIEN resource da co ma thieu tag
#
# File nay chi lam tang thu nhat.
# ---------------------------------------------------------------
#
# KHAC SCP O CHO GOP CHINH SACH:
#
#   SCP        GIAO NHAU - deny o bat ky tang nao la chan
#   tag policy KE THUA VA TRON - tang duoi co the them (@@append)
#              hoac ghi de (@@assign) tang tren
#
# Nen gan o root la phu het, va OU con van tinh chinh duoc.
#
# HAN MUC RIENG: 5 tag policy moi target, KHONG an chung slot voi
# 5 SCP. check "scp_count_per_target_under_limit" khong lien quan.
########################################

locals {
  tp = var.enable_tag_policy ? 1 : 0

  # Rap tung khoa theo dung khuon cua doc 11 muc 4.
  #
  # tag_key   luon co - day chinh la thu gia tri nhat: no ep DUNG
  #           CACH VIET. AWS coi CostCenter / costcenter / Cost_Center
  #           la BA tag khac nhau, va do la cach bang chi phi vo vun
  #           nhanh nhat.
  # tag_value chi xuat hien khi co allowed_values. Bo trong = gia tri
  #           nao cung duoc, van con rang buoc cach viet khoa.
  # enforced_for chi xuat hien khi co khai. Bo trong = CHI BAO CAO,
  #           khong chan gi.
  tag_policy_body = {
    tags = {
      for key, cfg in var.tag_policy_keys : key => merge(
        { tag_key = { "@@assign" = key } },
        length(cfg.allowed_values) > 0 ? { tag_value = { "@@assign" = cfg.allowed_values } } : {},
        length(cfg.enforced_for) > 0 ? { enforced_for = { "@@assign" = cfg.enforced_for } } : {},
      )
    }
  }

  # Khoa nao dang thuc su CHAN, khoa nao chi bao cao.
  tp_enforcing = [
    for key, cfg in var.tag_policy_keys : key if length(cfg.enforced_for) > 0
  ]

  # Root da bat TAG_POLICY chua. Chua bat thi CreatePolicy tra ve
  # PolicyTypeNotEnabledException.
  #
  # BA trang thai, khong phai hai. Doc duoc va thay -> ok. Doc duoc va
  # khong thay -> canh bao. KHONG DOC DUOC -> im lang.
  #
  # Truong hop thu ba co that: thuoc tinh roots[].policy_types doi hinh
  # qua cac ban provider. Gop no vao "khong bat" nghia la canh bao nguoi
  # dung bat mot thu da bat roi - va canh bao sai vai lan la nguoi ta
  # thoi doc canh bao.
  tp_root_enabled_types = try(
    [for p in local.org.roots[0].policy_types : p.type if p.status == "ENABLED"],
    null,
  )

  tp_enabled_on_root = (
    local.tp_root_enabled_types == null
    ? true
    : contains(local.tp_root_enabled_types, "TAG_POLICY")
  )

  # Loc truoc, khong de target khong phan giai duoc di toi apply.
  # check chi CANH BAO, ma canh bao thi apply van chay - va chay voi
  # target_id = null thi loi cua AWS khong nhac gi toi ten OU sai.
  tp_attachments = local.tp == 0 ? {} : {
    for t in var.tag_policy_targets :
    t => (t == "ROOT" ? local.root_id : try(local.ou_ids[t], null))
    if t == "ROOT" || try(local.ou_ids[t], null) != null
  }
}

resource "aws_organizations_policy" "tag" {
  count = local.tp

  name        = "${var.project}-tags"
  description = "Chuan hoa cach viet va gia tri cua tag chia chi phi"
  type        = "TAG_POLICY"

  content = jsonencode(local.tag_policy_body)
}

resource "aws_organizations_policy_attachment" "tag" {
  for_each = local.tp_attachments

  policy_id = aws_organizations_policy.tag[0].id
  target_id = each.value
}

########################################
# KIEM TRA CHEO
########################################

check "tag_policy_type_enabled" {
  assert {
    condition = local.tp == 0 || local.tp_enabled_on_root
    error_message = join(" ", [
      "enable_tag_policy = true nhung TAG_POLICY chua duoc bat tren root.",
      "CreatePolicy se tra ve PolicyTypeNotEnabledException.",
      "Voi create_organization = true thi them \"TAG_POLICY\" vao",
      "enabled_policy_types. Voi to chuc da co san thi bat bang tay:",
      "aws organizations enable-policy-type --root-id <root> --policy-type TAG_POLICY",
    ])
  }
}

check "tag_policy_is_report_only" {
  assert {
    condition = local.tp == 0 || length(local.tp_enforcing) > 0
    error_message = join(" ", [
      "Tag policy dang o che do CHI BAO CAO - khong khoa nao co enforced_for.",
      "Do la trang thai KHOI DAU dung: bat, xem bao cao tuan thu vai ngay,",
      "roi moi them enforced_for cho tung khoa mot.",
      "Nhung dung dung lai o day va tuong tag da duoc ep buoc.",
      "Xem bao cao: Resource Groups & Tag Editor -> Tag policies.",
    ])
  }
}

check "tag_policy_targets_resolve" {
  assert {
    condition = local.tp == 0 || alltrue([
      for t in var.tag_policy_targets :
      t == "ROOT" || contains(keys(local.ou_ids), t)
    ])
    error_message = format(
      "tag_policy_targets co ten OU khong ton tai: %s. Ten hop le: ROOT, %s",
      join(", ", [for t in var.tag_policy_targets : t if t != "ROOT" && !contains(keys(local.ou_ids), t)]),
      join(", ", sort(keys(local.ou_ids)))
    )
  }
}
