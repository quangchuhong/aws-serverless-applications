########################################
# GROUP - KHONG BAO GIO GAN QUYEN THANG CHO USER
#
# principal_type cua assignment chap nhan ca USER lan GROUP.
# Nhung gan cho USER thi:
#
#   them mot nguoi vao team  -> phai tao N assignment (N = so account)
#   nguoi do roi team        -> phai nho xoa du N cai; sot mot cai la
#                               quyen con treo va khong ai biet
#   audit "ai co quyen gi"   -> phai duyet tung account
#
# Voi 15 account x 3 muc quyen, gan theo user la 45 dong cho MOI nguoi.
# Gan theo group la 45 dong cho CA TO CHUC, roi moi nguoi them dung
# MOT dong membership.
#
# => Moi assignment trong layer nay deu la principal_type = "GROUP".
########################################

locals {
  groups = {
    "lz-platform-admins" = {
      description     = "Platform / Cloud engineering - full admin"
      permission_sets = ["lz-account-admin"]
    }

    "lz-billing-team" = {
      description     = "Finance / FinOps - chi o management account"
      permission_sets = ["lz-billing"]
    }

    "lz-auditors" = {
      description     = "Kiem toan noi bo / bo phan tuan thu - chi doc cau hinh"
      permission_sets = ["lz-auditor"]
    }

    "lz-network-admins" = {
      description     = "Doi mang - quan TGW, Network Firewall, Route 53, RAM"
      permission_sets = ["lz-network-admin"]
    }

    "lz-network-operators" = {
      description     = "Truc mang - chi doc"
      permission_sets = ["lz-network-operator"]
    }

    "lz-security-admins" = {
      description     = "Doi bao mat - IAM, KMS, GuardDuty, Config, CloudTrail"
      permission_sets = ["lz-security-admin"]
    }

    "lz-security-operators" = {
      description     = "Truc bao mat / SOC - chi doc"
      permission_sets = ["lz-security-operator"]
    }

    "lz-server-admins" = {
      description     = "Doi ha tang compute"
      permission_sets = ["lz-server-admin"]
    }

    "lz-server-operators" = {
      description     = "Truc van hanh compute - chi doc"
      permission_sets = ["lz-server-operator"]
    }

    "lz-db-admins" = {
      description     = "DBA - LUU Y: co quyen ghi len database production"
      permission_sets = ["lz-db-admin"]
    }

    "lz-db-operators" = {
      description     = "Chi doc database"
      permission_sets = ["lz-db-operator"]
    }

    "lz-analytics-admins" = {
      description     = "Doi du lieu - chi trong cac account Data Analytics"
      permission_sets = ["lz-analytics-admin"]
    }

    "lz-analytics-operators" = {
      description     = "Chi doc nen tang du lieu"
      permission_sets = ["lz-analytics-operator"]
    }

    "lz-datalake-admins" = {
      description     = "Quan tri Lake Formation - cap quyen DU LIEU. Rat it nguoi."
      permission_sets = ["lz-datalake-admin"]
    }

    # Mot group, HAI permission set, HAI pham vi khac nhau:
    #   lz-app-admin    -> scope nonprod -> ghi duoc o non-production
    #   lz-app-operator -> scope prod    -> chi doc o production
    #
    # Day chinh la cach hien thuc hoa quyet dinh "khong con nguoi nao
    # ghi duoc len prod application" ma khong can hai group rieng.
    "lz-app-teams" = {
      description     = "Doi ung dung - ghi o non-prod, chi doc o prod"
      permission_sets = ["lz-app-admin", "lz-app-operator"]
    }
  }
}

########################################
# Terraform lam chu group (khong co AD / IdP ngoai)
########################################

resource "aws_identitystore_group" "this" {
  for_each = var.manage_groups ? local.groups : {}

  identity_store_id = local.identity_store_id
  display_name      = each.key
  description       = each.value.description
}

########################################
# SCIM lam chu group (co AD / Entra / Okta)
#
# Khi do Terraform CHI DUOC DOC. Tao bang resource se xung dot voi
# SCIM: SCIM ghi de, Terraform thay drift, apply lai, lap vo tan.
# Xem doc 08.
########################################

data "aws_identitystore_group" "this" {
  for_each = var.manage_groups ? {} : local.groups

  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = each.key
    }
  }
}

locals {
  group_ids = var.manage_groups ? {
    for k, v in aws_identitystore_group.this : k => v.group_id
    } : {
    for k, v in data.aws_identitystore_group.this : k => v.group_id
  }
}

########################################
# USER - chi khi dung Identity Center directory
#
# Email o day CHI de nhan thu dat password. KHONG can duy nhat toan
# cau - rat khac email root account. Dung lai email ca nhan thoai mai,
# ke ca cung mot email cho nhieu user (tuy khong nen).
########################################

locals {
  # SCIM lam chu thi Terraform khong tao user - de rong.
  managed_users = var.manage_groups ? var.users : {}
}

resource "aws_identitystore_user" "this" {
  for_each = local.managed_users

  identity_store_id = local.identity_store_id

  user_name    = each.key
  display_name = "${each.value.given_name} ${each.value.family_name}"

  name {
    given_name  = each.value.given_name
    family_name = each.value.family_name
  }

  emails {
    value   = each.value.email
    primary = true
  }
}

resource "aws_identitystore_group_membership" "this" {
  for_each = {
    for pair in flatten([
      for uname, u in local.managed_users : [
        for g in u.groups : {
          key   = "${uname}|${g}"
          user  = uname
          group = g
        }
      ]
    ]) : pair.key => pair
  }

  identity_store_id = local.identity_store_id
  group_id          = local.group_ids[each.value.group]
  member_id         = aws_identitystore_user.this[each.value.user].user_id
}

########################################
# Group khai trong var.users phai ton tai
########################################

check "user_groups_exist" {
  assert {
    condition = length(setsubtract(
      toset(flatten([for _, u in var.users : u.groups])),
      toset(keys(local.groups)),
    )) == 0

    error_message = format(
      "var.users tham chieu group khong co trong local.groups: %s",
      join(", ", tolist(setsubtract(
        toset(flatten([for _, u in var.users : u.groups])),
        toset(keys(local.groups)),
      )))
    )
  }
}
