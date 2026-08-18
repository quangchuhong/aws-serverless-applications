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
  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
    "guardduty.amazonaws.com",
    "securityhub.amazonaws.com",
    "access-analyzer.amazonaws.com",
    "sso.amazonaws.com",
    "ram.amazonaws.com",
    "member.org.stacksets.cloudformation.amazonaws.com",
    "backup.amazonaws.com",
    "malware-protection.guardduty.amazonaws.com",
    "reports.billing.amazonaws.com",
  ]

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
}

########################################
# 3. Kiem tra cheo
########################################

check "ou_scopes_match_permission_sets" {
  assert {
    condition = alltrue([
      for required in ["Workloads/Non-Production", "Workloads/Production", "Data Analytics"] :
      contains(keys(local.ou_ids), required)
    ])

    error_message = join(" ", [
      "Thieu OU ma landing-zone/permission-sets trong doi:",
      "Workloads/Non-Production (scope nonprod),",
      "Workloads/Production (scope prod),",
      "Data Analytics (scope analytics).",
      "Doi ou_structure thi phai doi ca accounts_by_scope ben do.",
    ])
  }
}
