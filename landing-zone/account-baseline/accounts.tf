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

resource "aws_organizations_account" "this" {
  for_each = local.enabled ? var.create_accounts : {}

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
      for _, a in var.create_accounts : !startswith(a.parent_id, "r-")
    ])

    error_message = join(" ", [
      "Co account duoc tao thang vao ROOT thay vi mot OU.",
      "SCP gan vao OU, nen account o root chi con cac SCP gan o root -",
      "mat network_lock va prod_guard ma van chay binh thuong.",
      "Do dung la cai layer nay sinh ra de ngan.",
    ])
  }
}
