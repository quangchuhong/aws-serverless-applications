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

########################################
# Pham vi RONG = permission set khong gan cho ai
#
# Danh sach pham vi can kiem duoc SUY RA tu chinh permission_sets chu
# khong viet cung. Viet cung nghia la them mot pham vi moi thi phai
# nho them vao day - va lan them "security" da chung minh dieu do:
# neu core_accounts.security de rong, lz-security-admin sinh ra 0
# assignment, khong ai quan tri duoc account bao mat, va khong co dong
# nao noi ra.
#
# "none" loai tru: lz-app-breakglass co y khong gan cho ai (doc 19).
########################################

locals {
  scopes_in_use = distinct([
    for _, v in local.permission_sets : v.scope if v.scope != "none"
  ])

  empty_scopes = [
    for s in local.scopes_in_use : s if length(local.scope_accounts[s]) == 0
  ]

  # Hai nguyen nhan khac han nhau, nen tach de thong bao noi dung viec.
  #   core     -> quen mot dong trong core_accounts
  #   moi truong -> chua co OU do, thuong la binh thuong
  empty_core_scopes = [
    for s in local.empty_scopes : s if contains(["security", "network", "workloads"], s)
  ]
}

check "declared_scopes_not_empty" {
  assert {
    condition = length(local.empty_scopes) == 0

    error_message = join(" ", compact([
      "Pham vi RONG nen khong sinh assignment nao:",
      join(", ", local.empty_scopes),
      ".",
      length(local.empty_core_scopes) > 0
      ? format(
        "Trong do %s la pham vi HA TANG LOI - khai thieu trong var.core_accounts. Vi du pham vi 'security' rong nghia la lz-security-admin khong duoc gan vao dau ca, va khong ai quan tri duoc account bao mat.",
        join(", ", local.empty_core_scopes)
      )
      : "",
      "Cac pham vi moi truong (analytics, nonprod, prod) khai trong var.accounts_by_scope; chua co OU do thi bo qua.",
    ]))
  }
}
