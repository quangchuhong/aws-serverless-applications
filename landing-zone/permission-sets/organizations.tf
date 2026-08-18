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

  scope_accounts = {
    all        = local.all_accounts
    management = [var.management_account_id]
    analytics  = try(var.accounts_by_scope["analytics"], [])
    nonprod    = try(var.accounts_by_scope["nonprod"], [])
    prod       = try(var.accounts_by_scope["prod"], [])
    none       = []
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
