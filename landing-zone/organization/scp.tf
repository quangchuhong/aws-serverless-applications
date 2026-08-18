########################################
# SCP
#
# HAI GIOI HAN CUA AWS quyet dinh cach file nay duoc viet:
#
#   1. Toi da 5 policy gan vao MOT root/OU/account.
#      FullAWSAccess da chiem 1 -> con 4.
#      => Khong viet 10 SCP nho, phai gom thanh vai SCP lon.
#
#   2. Moi SCP toi da 5120 ky tu.
#      => jsonencode (khong xuong dong) chu khong phai file JSON
#         dinh dang dep. Chay ./validate-scp.sh de do.
#
# NHAC LAI: SCP la TRAN QUYEN, khong cap quyen. Mot action chay duoc
# chi khi CA permission set LAN SCP cho phep. Va SCP KHONG ap dung
# cho management account.
########################################

locals {
  # Duong mien tru dung chung. Rong thi khong sinh Condition nao ca -
  # "ArnNotLike" voi mang rong la JSON hop le nhung y nghia mo ho.
  exempt_arns = [
    for r in var.scp_exempt_role_names :
    "arn:${local.partition}:iam::*:role/${r}"
  ]

  has_exempt = length(local.exempt_arns) > 0

  exempt_condition = local.has_exempt ? {
    ArnNotLike = { "aws:PrincipalArn" = local.exempt_arns }
  } : null

  ####################################
  # 1. BASELINE - gan vao Root
  #
  # Bao ve chinh co che kiem soat. Neu chi bat duoc MOT SCP thi
  # bat cai nay.
  ####################################

  stmt_baseline = [
    jsonencode(merge({
      Sid    = "ProtectOrganizationMembership"
      Effect = "Deny"
      Action = [
        "organizations:LeaveOrganization",
        "organizations:DeleteOrganization",
        "organizations:RemoveAccountFromOrganization",
        "organizations:DisablePolicyType",
        "organizations:DetachPolicy",
        "organizations:DeletePolicy",
        "account:CloseAccount",
      ]
      Resource = "*"
    }, local.has_exempt ? { Condition = local.exempt_condition } : {})),

    jsonencode(merge({
      Sid    = "ProtectAuditTrail"
      Effect = "Deny"
      Action = [
        "cloudtrail:StopLogging",
        "cloudtrail:DeleteTrail",
        "cloudtrail:UpdateTrail",
        "cloudtrail:PutEventSelectors",
        "config:DeleteConfigurationRecorder",
        "config:StopConfigurationRecorder",
        "config:DeleteDeliveryChannel",
        "config:DeleteRetentionConfiguration",
        "guardduty:DeleteDetector",
        "guardduty:UpdateDetector",
        "guardduty:DisassociateFromMasterAccount",
        "securityhub:DisableSecurityHub",
        "access-analyzer:DeleteAnalyzer",
      ]
      Resource = "*"
    }, local.has_exempt ? { Condition = local.exempt_condition } : {})),

    # Root user cua account con khong duoc lam gi ngoai viec tu cuu
    # minh. Buoc moi thao tac thuong ngay di qua Identity Center.
    jsonencode({
      Sid       = "DenyRootUserActions"
      Effect    = "Deny"
      NotAction = ["iam:CreateVirtualMFADevice", "iam:EnableMFADevice", "iam:ResyncMFADevice", "iam:ChangePassword"]
      Resource  = "*"
      Condition = { StringLike = { "aws:PrincipalArn" = "arn:${local.partition}:iam::*:root" } }
    }),

    # Ep dung Identity Center thay vi IAM user. IAM user co access key
    # dai han - thu de ro nhat va kho thu hoi nhat.
    jsonencode(merge({
      Sid    = "DenyIamUserCreation"
      Effect = "Deny"
      Action = [
        "iam:CreateUser",
        "iam:CreateAccessKey",
        "iam:CreateLoginProfile",
      ]
      Resource = "*"
    }, local.has_exempt ? { Condition = local.exempt_condition } : {})),

    # Khong ai duoc mo public access block o muc account
    jsonencode({
      Sid      = "ProtectS3PublicAccessBlock"
      Effect   = "Deny"
      Action   = ["s3:PutAccountPublicAccessBlock"]
      Resource = "*"
    }),
  ]

  ####################################
  # 2. REGION LOCK - gan vao Root
  #
  # NotAction liet ke dich vu TOAN CAU. Goi API cua chung luon di
  # toi mot region cu the (thuong us-east-1) va khong the ep theo
  # allowed_regions - chan chung la tu khoa minh ra ngoai.
  ####################################

  stmt_region_lock = [
    jsonencode({
      Sid    = "DenyOutsideAllowedRegions"
      Effect = "Deny"
      NotAction = [
        "iam:*", "organizations:*", "sts:*", "account:*",
        "route53:*", "route53domains:*", "cloudfront:*",
        "waf:*", "waf-regional:*", "wafv2:*", "shield:*",
        "globalaccelerator:*", "networkmanager:*",
        "support:*", "trustedadvisor:*", "health:*",
        "budgets:*", "ce:*", "cur:*", "billing:*", "payments:*",
        "tax:*", "consolidatedbilling:*", "invoicing:*", "freetier:*",
        "sso:*", "sso-directory:*", "identitystore:*",
        "artifact:*", "quicksight:*", "chatbot:*",
        "cloudtrail:LookupEvents", "kms:DescribeKey",
      ]
      Resource = "*"
      Condition = merge(
        { StringNotEquals = { "aws:RequestedRegion" = var.allowed_regions } },
        local.has_exempt ? local.exempt_condition : {},
      )
    }),
  ]

  ####################################
  # 3. NETWORK LOCK
  #
  # Gan vao Workloads / Data Analytics / Sandbox - KHONG gan vao
  # Infrastructure (network account song o do va can dung nhung
  # action nay).
  #
  # Nguon: doc 13.
  ####################################

  network_exempt_condition = var.network_account_id != "" ? {
    StringNotEquals = { "aws:PrincipalAccount" = var.network_account_id }
  } : null

  stmt_network_lock = [
    jsonencode(merge({
      Sid    = "DenyInternetGateways"
      Effect = "Deny"
      Action = [
        "ec2:CreateInternetGateway",
        "ec2:AttachInternetGateway",
        "ec2:CreateEgressOnlyInternetGateway",
        "ec2:CreateCarrierGateway",
        "ec2:CreateDefaultVpc",
        "ec2:CreateDefaultSubnet",
        "ec2:CreateNatGateway",
        "ec2:AllocateAddress",
        "ec2:AssociateAddress",
      ]
      Resource = "*"
    }, var.network_account_id != "" ? { Condition = local.network_exempt_condition } : {})),

    jsonencode(merge({
      Sid    = "DenyCrossVpcShortcuts"
      Effect = "Deny"
      Action = [
        "ec2:CreateVpcPeeringConnection",
        "ec2:AcceptVpcPeeringConnection",
        "ec2:CreateTransitGateway",
        "ec2:CreateVpnGateway",
        "ec2:CreateVpnConnection",
        "ec2:CreateClientVpnEndpoint",
        "directconnect:CreateConnection",
        "directconnect:CreateDirectConnectGateway",
      ]
      Resource = "*"
    }, var.network_account_id != "" ? { Condition = local.network_exempt_condition } : {})),

    # Chan IP public ngay tu luc launch. Khong co dong nay thi mot
    # instance co the ra thang Internet ma khong qua security VPC.
    jsonencode({
      Sid      = "DenyPublicIpOnLaunch"
      Effect   = "Deny"
      Action   = "ec2:RunInstances"
      Resource = "arn:${local.partition}:ec2:*:*:instance/*"
      Condition = {
        Bool = { "ec2:AssociatePublicIpAddress" = "true" }
      }
    }),
  ]

  ####################################
  # 4. PROD GUARD - gan vao Workloads/Production
  #
  # Chan thao tac PHA HUY KHONG PHUC HOI DUOC.
  #
  # Khong chan sua doi thong thuong - viec do da do permission set
  # lo (lz-app-operator chi doc o prod, doc 19 muc 2).
  ####################################

  stmt_prod_guard = [
    jsonencode({
      Sid    = "ProtectBackupsAndSnapshots"
      Effect = "Deny"
      Action = [
        "rds:DeleteDBClusterSnapshot",
        "rds:DeleteDBSnapshot",
        "ec2:DeleteSnapshot",
        "backup:DeleteBackupVault",
        "backup:DeleteRecoveryPoint",
        "backup:DeleteBackupPlan",
        "backup:PutBackupVaultAccessPolicy",
        "dynamodb:DeleteBackup",
      ]
      Resource = "*"
    }),

    jsonencode({
      Sid    = "ProtectEncryptionKeys"
      Effect = "Deny"
      Action = [
        "kms:ScheduleKeyDeletion",
        "kms:DisableKey",
        "kms:DisableKeyRotation",
      ]
      Resource = "*"
    }),

    # Tat versioning tren bucket state hay bucket log = mat kha nang
    # khoi phuc. Day la thao tac gan nhu khong bao gio dung o prod.
    jsonencode({
      Sid    = "ProtectS3Recovery"
      Effect = "Deny"
      Action = [
        "s3:PutBucketVersioning",
        "s3:PutBucketPolicy",
        "s3:DeleteBucketPolicy",
        "s3:PutBucketLogging",
      ]
      Resource = "*"
    }),
  ]

  ####################################
  # Gom lai
  ####################################

  scp_definitions = {
    baseline = {
      enabled     = try(var.enable_scp.baseline, true)
      description = "Bao ve co che kiem soat: roi to chuc, audit trail, root user, IAM user"
      statements  = local.stmt_baseline
      targets     = ["ROOT"]
    }

    region_lock = {
      enabled     = try(var.enable_scp.region_lock, true)
      description = "Chi cho phep ${join(", ", var.allowed_regions)}"
      statements  = local.stmt_region_lock
      targets     = ["ROOT"]
    }

    network_lock = {
      enabled     = try(var.enable_scp.network_lock, true)
      description = "Khoa duong ra Internet truc tiep - moi traffic qua account network"
      statements  = local.stmt_network_lock
      targets     = ["Workloads", "Data Analytics", "Sandbox"]
    }

    prod_guard = {
      enabled     = try(var.enable_scp.prod_guard, true)
      description = "Chan thao tac pha huy khong phuc hoi duoc o production"
      statements  = local.stmt_prod_guard
      targets     = ["Workloads/Production"]
    }
  }

  scp_enabled = { for k, v in local.scp_definitions : k => v if v.enabled }

  # (policy, target) -> mot attachment
  scp_attachments = var.scp_dry_run ? {} : {
    for item in flatten([
      for name, def in local.scp_enabled : [
        for t in def.targets : {
          key    = "${name}|${t}"
          policy = name
          target = t == "ROOT" ? local.root_id : try(local.ou_ids[t], null)
        }
      ]
    ]) : item.key => item if item.target != null
  }
}

########################################
# RESOURCE
########################################

resource "aws_organizations_policy" "scp" {
  for_each = local.scp_enabled

  name        = "${var.project}-${replace(each.key, "_", "-")}"
  description = each.value.description
  type        = "SERVICE_CONTROL_POLICY"

  content = format(
    "{\"Version\":\"2012-10-17\",\"Statement\":[%s]}",
    join(",", each.value.statements)
  )
}

resource "aws_organizations_policy_attachment" "scp" {
  for_each = local.scp_attachments

  policy_id = aws_organizations_policy.scp[each.value.policy].id
  target_id = each.value.target
}

########################################
# KIEM TRA GIOI HAN
########################################

check "scp_size_under_limit" {
  assert {
    condition = alltrue([
      for k, v in local.scp_enabled :
      length(format("{\"Version\":\"2012-10-17\",\"Statement\":[%s]}", join(",", v.statements))) <= 5120
    ])

    error_message = format(
      "SCP vuot 5120 ky tu: %s",
      join(", ", [
        for k, v in local.scp_enabled :
        "${k}=${length(format("{\"Version\":\"2012-10-17\",\"Statement\":[%s]}", join(",", v.statements)))}"
        if length(format("{\"Version\":\"2012-10-17\",\"Statement\":[%s]}", join(",", v.statements))) > 5120
      ])
    )
  }
}

check "scp_count_per_target_under_limit" {
  assert {
    # FullAWSAccess luon chiem 1 slot -> toi da 4 SCP tu viet
    condition = alltrue([
      for target in distinct([for _, a in local.scp_attachments : a.target]) :
      length([for _, a in local.scp_attachments : a if a.target == target]) <= 4
    ])

    error_message = "Mot target dang co qua 4 SCP tu viet. AWS gioi han 5 policy/target, FullAWSAccess chiem 1."
  }
}
