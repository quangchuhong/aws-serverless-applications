########################################
# PHAM VI ACCOUNT
#
# HAN CHE PHAI BIET TRUOC KHI DOC FILE NAY:
#
#   Identity Center KHONG gan assignment cho OU.
#   target_type chi nhan "AWS_ACCOUNT".
#
# Rat tu nhien khi nghi "gan lz-app-admin cho OU Non-Production",
# nhung khong lam duoc. Phai liet ke tung account ID.
#
# Nen o day:
#   - pham vi "all" suy ra tu Organizations (tu dong, khong phai khai)
#   - bon pham vi con lai khai trong var.accounts_by_scope
#
# HE QUA VAN HANH: tao account moi trong OU non-prod thi phai them
# vao terraform.tfvars roi apply lai, KHONG thi khong ai vao duoc
# account do - va nguoi ta se quay ra dung root. Gan buoc nay vao
# account vending (doc 09 muc 5).
########################################

data "aws_organizations_organization" "this" {}

locals {
  # Chi account dang ACTIVE. Account SUSPENDED van nam trong
  # organization nhung tao assignment se loi.
  active_accounts = [
    for a in data.aws_organizations_organization.this.accounts :
    a.id if a.status == "ACTIVE"
  ]

  # Management account nen loai khoi "all": SCP KHONG ap dung cho no,
  # moi quyen cap o day la quyen that khong co tran chan.
  all_accounts = var.exclude_management_from_all ? [
    for id in local.active_accounts : id if id != var.management_account_id
  ] : local.active_accounts

  # Ba account ha tang loi. "all" van gom chung - do la co y, vi
  # lz-account-admin va lz-auditor phai vao duoc moi noi. Cai duoc
  # tach ra la nhung set KHONG can toi chung.
  core_accounts = compact([
    var.core_accounts.security,
    var.core_accounts.log_archive,
    var.core_accounts.network,
  ])

  scope_accounts = {
    # Moi account thanh vien. CHI danh cho set that su can di khap noi:
    # quan tri, kiem toan, va chi-doc bao mat.
    all = local.all_accounts

    management = [var.management_account_id]

    # Account HA TANG LOI - tach rieng de set van hanh workload khong
    # cham toi. Rong thi khong sinh assignment nao, dung y muon.
    security = compact([var.core_accounts.security])
    network  = compact([var.core_accounts.network])

    # MOI account TRU ba account loi.
    #
    # Day la pham vi dung cho lz-db-* va lz-server-*: chung quan
    # database va compute, ma ba account kia khong chay thu nao ca.
    # Truoc khi tach, lz-server-admin nhan s3:* trong account log
    # archive - tuc xoa duoc bang chung kiem toan.
    #
    # core_accounts de rong thi cai nay = all, va khong tach duoc gi.
    workloads = [
      for id in local.all_accounts : id if !contains(local.core_accounts, id)
    ]

    analytics = try(var.accounts_by_scope["analytics"], [])
    nonprod   = try(var.accounts_by_scope["nonprod"], [])
    prod      = try(var.accounts_by_scope["prod"], [])
    none      = []
  }
}

########################################
# KIEM TRA CHEO
########################################

check "core_accounts_declared" {
  assert {
    condition = length(local.core_accounts) > 0
    error_message = join(" ", [
      "core_accounts de rong nen pham vi \"workloads\" bang dung \"all\".",
      "Nghia la lz-server-admin va lz-db-admin van duoc gan vao account",
      "security, log archive va network - va lz-server-admin co s3:*,",
      "tuc xoa duoc bang chung trong bucket CloudTrail/Config.",
      "Khai core_accounts de lop tach nay co tac dung.",
    ])
  }
}

check "core_accounts_are_real_members" {
  assert {
    condition = alltrue([
      for id in local.core_accounts : contains(local.active_accounts, id)
    ])
    error_message = join(" ", [
      "Co account ID trong core_accounts khong phai thanh vien ACTIVE",
      "cua to chuc. Sai ID thi no khong loai duoc gi khoi \"workloads\"",
      "- lop tach im lang khong hoat dong. Doi chieu:",
      "aws organizations list-accounts --query 'Accounts[].[Id,Name]' --output table",
    ])
  }
}

########################################
# TU DONG SINH PHAM VI TU OU - TUY CHON
#
# Neu provider AWS cua ban co data source duoi day thi thay
# var.accounts_by_scope bang no, khoi phai bao tri tay:
#
#   data "aws_organizations_organizational_unit_descendant_accounts" "nonprod" {
#     parent_id = var.ou_ids["non-production"]
#   }
#
#   locals {
#     nonprod = data.aws_organizations_organizational_unit_descendant_accounts.nonprod.accounts[*].id
#   }
#
# KIEM CHUNG TRUOC KHI DUNG - ten va schema cua cac data source
# vung Organizations co thay doi qua cac ban provider:
#
#   terraform providers schema -json \
#     | jq '.provider_schemas[].data_source_schemas
#           | keys[] | select(startswith("aws_organizations"))'
#
# Layer nay giu duong bien de chac chan chay duoc tren moi ban.
########################################

########################################
# KIEM TRA CHEO: account khai trong bien co that su ton tai khong
########################################

check "accounts_exist_in_org" {
  assert {
    condition = length(setsubtract(
      toset(flatten(values(var.accounts_by_scope))),
      toset(local.active_accounts),
    )) == 0

    error_message = format(
      "Account khai trong accounts_by_scope nhung khong ACTIVE trong organization: %s",
      join(", ", tolist(setsubtract(
        toset(flatten(values(var.accounts_by_scope))),
        toset(local.active_accounts),
      )))
    )
  }
}

check "no_account_in_two_env_scopes" {
  assert {
    condition = length(setintersection(
      toset(try(var.accounts_by_scope["nonprod"], [])),
      toset(try(var.accounts_by_scope["prod"], [])),
    )) == 0

    error_message = "Mot account khong the vua nonprod vua prod - se duoc ca lz-app-admin lan lz-app-operator."
  }
}
