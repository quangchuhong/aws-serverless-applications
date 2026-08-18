########################################
# MA TRAN GAN QUYEN
#
#   assignment = (group, permission set, account)
#
# So assignment sinh ra = tong cua, voi moi group, moi permission set
# cua group do, so account trong pham vi cua permission set do.
#
# Permission set co scope = "none" (break-glass) sinh ra 0 assignment.
# Do la co y - xem doc 19 muc 2.2.
#
# NHAC LAI: moi assignment lam Identity Center TU TAO MOT IAM ROLE
# trong account dich, ten dang:
#   AWSReservedSSO_<permission-set>_<hash>
# Sua permission set -> Identity Center day thay doi xuong tat ca
# cac role da sinh.
########################################

locals {
  assignments = merge([
    for gname, g in local.groups : {
      for item in flatten([
        for ps in g.permission_sets : [
          for account_id in local.scope_accounts[local.permission_sets[ps].scope] : {
            key            = "${gname}|${ps}|${account_id}"
            group          = gname
            permission_set = ps
            account_id     = account_id
          }
        ]
      ]) : item.key => item
    }
  ]...)
}

resource "aws_ssoadmin_account_assignment" "this" {
  for_each = local.assignments

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.permission_set].arn

  principal_id   = local.group_ids[each.value.group]
  principal_type = "GROUP"

  target_id   = each.value.account_id
  target_type = "AWS_ACCOUNT"

  # Inline policy phai ton tai truoc khi gan, neu khong co mot khoang
  # thoi gian ngan role da duoc tao ma chua co quyen dung.
  depends_on = [
    aws_ssoadmin_permission_set_inline_policy.this,
    aws_ssoadmin_managed_policy_attachment.this,
  ]
}

########################################
# Moi permission set phai co it nhat mot group dung toi
#
# Bat loi "tao permission set roi quen gan" - rat de xay ra khi bang
# thiet ke va code lech nhau.
########################################

check "every_permission_set_is_granted" {
  assert {
    condition = length(setsubtract(
      toset([for k, v in local.permission_sets : k if v.scope != "none"]),
      toset(flatten([for _, g in local.groups : g.permission_sets])),
    )) == 0

    error_message = format(
      "Permission set khong duoc group nao dung toi: %s",
      join(", ", tolist(setsubtract(
        toset([for k, v in local.permission_sets : k if v.scope != "none"]),
        toset(flatten([for _, g in local.groups : g.permission_sets])),
      )))
    )
  }
}

########################################
# Pham vi da khai nhung rong -> canh bao som
#
# Khai analytics/nonprod/prod rong thi cac set tuong ung sinh ra 0
# assignment va khong ai vao duoc. Im lang thi rat kho phat hien.
########################################

check "declared_scopes_not_empty" {
  assert {
    condition = alltrue([
      for s in ["analytics", "nonprod", "prod"] :
      length(local.scope_accounts[s]) > 0
    ])

    error_message = join(" ", [
      "Cac pham vi sau dang RONG nen khong sinh assignment nao:",
      join(", ", [for s in ["analytics", "nonprod", "prod"] : s if length(local.scope_accounts[s]) == 0]),
      "- khai account ID trong var.accounts_by_scope.",
      "Neu chua co OU do thi bo qua canh bao nay.",
    ])
  }
}
