########################################
# 1. Organization
#
# Hai duong: tao moi, hoac doc cai da co.
#
# feature_set = "ALL" la bat buoc - "CONSOLIDATED_BILLING" khong
# dung duoc SCP. Doi tu CONSOLIDATED_BILLING sang ALL duoc, nhung
# can moi tung account con xac nhan, khong tu dong.
########################################

resource "aws_organizations_organization" "this" {
  count = var.create_organization ? 1 : 0

  feature_set = "ALL"

  enabled_policy_types = [
    "SERVICE_CONTROL_POLICY",
    "TAG_POLICY",
    "BACKUP_POLICY",
  ]

  # Cho phep cac dich vu hoat dong o pham vi to chuc. Thieu mot dong
  # o day thi dich vu tuong ung khong bat duoc delegated admin hay
  # khong doc duoc cay OU.
  #
  # CANH BAO: CHI MOT service principal sai la HONG CA RESOURCE.
  # AWS tra ve InvalidInputException "You specified an unrecognized
  # service principal" va khong noi CAI NAO sai. Organization co the
  # da duoc tao roi moi loi o buoc nay - khi do phai import.
  #
  # => Chi them principal khi da kiem chung. Danh sach hop le:
  #      https://docs.aws.amazon.com/organizations/latest/userguide/orgs_integrate_services_list.html
  #    hoac xem cai dang bat:
  #      aws organizations list-aws-service-access-for-organization
  aws_service_access_principals = var.aws_service_access_principals

  # Xoa organization = moi account con bi tach ra, va cac dich vu
  # pham vi to chuc (CloudTrail org trail, SCP, RAM share) ngung
  # hoat dong. Khong the lo tay.
  lifecycle {
    prevent_destroy = true
  }
}

data "aws_organizations_organization" "existing" {
  count = var.create_organization ? 0 : 1
}

locals {
  org = var.create_organization ? aws_organizations_organization.this[0] : data.aws_organizations_organization.existing[0]

  root_id   = local.org.roots[0].id
  org_id    = local.org.id
  partition = data.aws_partition.current.partition

  # Danh sach account dang ACTIVE - dung cho output kiem tra
  active_accounts = try([
    for a in local.org.accounts : a.id if a.status == "ACTIVE"
  ], [])
}

########################################
# 2. Cay OU
#
# Hai cap. Sau hon nua thi kho theo doi va it khi can that.
########################################

resource "aws_organizations_organizational_unit" "level1" {
  for_each = var.ou_structure

  name      = each.key
  parent_id = local.root_id

  # Xoa OU khi trong no con account se loi. Nhung neu OU rong thi
  # Terraform xoa duoc - va moi SCP gan vao no bien mat theo.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_organizations_organizational_unit" "level2" {
  for_each = {
    for item in flatten([
      for parent, children in var.ou_structure : [
        for child in children : {
          key    = "${parent}/${child}"
          name   = child
          parent = parent
        }
      ]
    ]) : item.key => item
  }

  name      = each.value.name
  parent_id = aws_organizations_organizational_unit.level1[each.value.parent].id

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  # Ban do ten -> OU id, gop ca hai cap.
  # Cap 1 dung ten tran: "Workloads"
  # Cap 2 dung duong dan : "Workloads/Production"
  ou_ids = merge(
    { for k, v in aws_organizations_organizational_unit.level1 : k => v.id },
    { for k, v in aws_organizations_organizational_unit.level2 : k => v.id },
  )

  ########################################
  # SCOPE -> OU ID, khong phu thuoc cach khai ou_structure
  #
  # Ba scope duoi day co y nghia o layer khac (permission-sets doc
  # chung, account-baseline dat account theo chung). Nhung TEN OU thi
  # do ou_structure quyet dinh, va ou_structure la mot bien:
  #
  #   long nhau   "Workloads/Production"
  #   phang       "Production"
  #   go tay      "Prod"
  #
  # Truoc day cac cho dung deu tra cuu MOT chuoi cung
  # ("Workloads/Production") boc trong try(..., ""). Khai phang thi
  # tra cuu do truot, try tra ve chuoi rong, va output goi y in ra mot
  # o TRONG ma khong noi tai sao. Nguoi doc thay mot o trong va di tim
  # xem minh quen dien gi.
  ########################################
  ou_scope_names = {
    nonprod   = ["Workloads/Non-Production", "Non-Production", "NonProd"]
    prod      = ["Workloads/Production", "Production", "Prod"]
    analytics = ["Data Analytics", "Analytics"]
  }

  ou_scope_ids = {
    for s, names in local.ou_scope_names :
    s => try(coalesce([for n in names : try(local.ou_ids[n], null)]...), "")
  }
}

########################################
# 3. Kiem tra cheo
########################################

check "ou_scopes_match_permission_sets" {
  assert {
    # Hoi theo SCOPE, khong hoi theo mot cach viet ten cu the. Truoc
    # day khoi nay doi dung chuoi "Workloads/Production", nen mot cay
    # OU phang - hop le, va la cay dang chay that - lam no do vinh
    # vien trong khi khong co gi sai.
    condition = alltrue([for s, id in local.ou_scope_ids : id != ""])

    error_message = join(" ", [
      "Khong tim thay OU cho scope:",
      join(", ", [for s, id in local.ou_scope_ids : s if id == ""]),
      ". landing-zone/permission-sets va account-baseline deu can chung.",
      "Ten da thu:",
      join(" | ", [for s, ns in local.ou_scope_names : "${s}: ${join(", ", ns)}"]),
      ". OU co that:", join(", ", sort(keys(local.ou_ids))),
      ". Doi ou_structure thi phai doi ca accounts_by_scope ben do.",
    ])
  }
}
