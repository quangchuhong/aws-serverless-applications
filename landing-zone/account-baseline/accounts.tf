########################################
# VENDING ACCOUNT - MAC DINH TAT
#
# Tao account THANG vao dung OU. Khong con buoc move-account, tuc
# khong con cho de quen.
#
# ---------------------------------------------------------------
# GAN NHU KHONG HOAN TAC DUOC
#
# Account khong xoa duoc, chi dong duoc, va dong xong phai cho 90
# ngay. Email thi duy nhat vinh vien - dong account roi cung khong
# dung lai duoc email do.
#
# Vi vay:
#   - create_accounts mac dinh RONG
#   - close_on_deletion mac dinh FALSE: destroy chi go khoi state
#   - prevent_destroy chan destroy nham
########################################

########################################
# CATALOG YEU CAU -> DANH SACH ACCOUNT
#
# Hai nguon, gop lai:
#
#   catalog/accounts.yaml   duong chinh. Mot khoi = mot yeu cau, di
#                           qua PR, co lint.sh chan truoc
#   var.create_accounts     duong cu, giu lai cho account da tao
#                           truoc khi co catalog
#
# KHOA LA TEN ACCOUNT, VA KHOA DI VAO STATE.
#
# Doi ten mot account trong catalog KHONG doi ten account that. No
# lam Terraform thay mot khoa bien mat va mot khoa moi xuat hien,
# tuc: tao MOT ACCOUNT MOI, va go account cu khoi state. Ca hai deu
# gan nhu khong hoan tac duoc.
#
# prevent_destroy o duoi chan ve thu hai. Khong co gi chan ve thu
# nhat ngoai viec doc ky - nen chu thich nay nam o day.
########################################

locals {
  catalog_raw = try(
    yamldecode(file("${path.module}/${var.catalog_dir}/accounts.yaml")).accounts,
    [],
  )

  # ou (TEN) -> parent_id. Go nham ten thi dung o precondition kem
  # danh sach ten hop le; go nham ID thi Terraform bao mot loi API
  # khong nhac gi toi viec ban go nham.
  catalog_accounts = {
    for a in local.catalog_raw : a.name => {
      email     = a.email
      parent_id = try(var.ou_ids[a.ou], "ou-KHONG-GIAI-DUOC")
    }
  }

  # var.create_accounts di SAU: khai o ca hai cho thi tfvars thang.
  # Precondition ben duoi chan truong hop do truoc khi no xay ra.
  accounts = merge(local.catalog_accounts, var.create_accounts)

  catalog_dupes = [
    for k in keys(local.catalog_accounts) : k if contains(keys(var.create_accounts), k)
  ]

  catalog_bad_ou = [
    for a in local.catalog_raw : "${a.name} (ou=${try(a.ou, "thieu")})"
    if !contains(keys(var.ou_ids), try(a.ou, ""))
  ]
}

resource "aws_organizations_account" "this" {
  for_each = local.enabled ? local.accounts : {}

  name      = each.key
  email     = each.value.email
  parent_id = each.value.parent_id

  # Role de vao account moi. Cung ten voi account tao tay bang
  # create-account, nen moi thu khac trong repo dung duoc ngay.
  role_name = "OrganizationAccountAccessRole"

  # false = terraform destroy chi go khoi state, KHONG dong account.
  # Xem var.close_accounts_on_destroy truoc khi doi.
  close_on_deletion = var.close_accounts_on_destroy

  # AWS tu dat mot so tag khi tao; dung de chung gay diff moi lan plan.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name, iam_user_access_to_billing]
  }
}

########################################
# KIEM TRA CHEO
########################################

check "closing_accounts_is_deliberate" {
  assert {
    condition     = !var.close_accounts_on_destroy
    error_message = "close_accounts_on_destroy = true: terraform destroy se DONG account that. Account dong roi phai cho 90 ngay, va email khong bao gio dung lai duoc. Chi bat khi that su co y do."
  }
}

check "new_accounts_go_to_an_ou" {
  assert {
    condition = alltrue([
      for _, a in local.accounts : !startswith(a.parent_id, "r-")
    ])

    error_message = join(" ", [
      "Co account duoc tao thang vao ROOT thay vi mot OU.",
      "SCP gan vao OU, nen account o root chi con cac SCP gan o root -",
      "mat network_lock va prod_guard ma van chay binh thuong.",
      "Do dung la cai layer nay sinh ra de ngan.",
    ])
  }
}


########################################
# CHAN TRUOC KHI TAO ACCOUNT
#
# Dat o mot resource rieng chu khong o chinh aws_organizations_account:
# precondition tren resource do chi chay khi resource do duoc tinh, va
# ta muon plan dung NGAY - truoc khi co bat cu lenh goi API nao.
########################################

resource "terraform_data" "catalog_guard" {
  count = local.enabled ? 1 : 0

  input = {
    accounts = length(local.accounts)
    catalog  = length(local.catalog_raw)
  }

  lifecycle {
    precondition {
      condition     = length(local.catalog_bad_ou) == 0
      error_message = "catalog/accounts.yaml: ${join(", ", local.catalog_bad_ou)} - ten OU khong giai duoc thanh ID. Ten hop le: ${join(", ", sort(keys(var.ou_ids)))}. Lay day du bang: cd ../organization && terraform output ou_ids"
    }

    precondition {
      condition     = length(local.catalog_dupes) == 0
      error_message = "Account khai o CA HAI cho: ${join(", ", local.catalog_dupes)}. Chung nam trong catalog/accounts.yaml va trong var.create_accounts, va tfvars dang de len catalog. Bo mot ben - catalog la duong chinh."
    }

    precondition {
      condition = alltrue([
        for a in local.catalog_raw :
        can(regex("^[^@[:space:]]+@[^@[:space:]]+$", try(a.email, "")))
      ])
      error_message = "catalog/accounts.yaml co email khong hop le. Email account la DUY NHAT VINH VIEN o pham vi AWS toan cau - go nham thi khong sua duoc, va email dung thi khong ai dung duoc nua. Chay ./lint.sh de biet dong nao."
    }

    precondition {
      condition = length(local.catalog_raw) == length(distinct([
        for a in local.catalog_raw : try(a.email, "")
      ]))
      error_message = "catalog/accounts.yaml co hai account dung chung mot email. AWS se tu choi cai thu hai o GIUA apply, sau khi cai thu nhat da duoc tao."
    }
  }
}
