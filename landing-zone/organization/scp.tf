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
  # SUSPENDED - dong bang account khong con dung
  #
  # Account khong xoa duoc, chi dong duoc - va dong la quyet dinh
  # khong lui duoc: 90 ngay moi roi to chuc, email chay vinh vien.
  # OU nay la duong o giua: account van ton tai, nhung khong lam
  # duoc gi.
  #
  # MOT statement duy nhat, va co y de no tho nhu vay. "Dong bang"
  # ma con ngoai le thi khong con la dong bang, va moi ngoai le la
  # mot cho phai kiem lai sau nay.
  #
  # HE QUA PHAI BIET TRUOC:
  #
  #   - KHONG don duoc tai nguyen trong account dang o day. Muon don
  #     thi park-account.sh --restore dua no ra truoc.
  #   - SCP chan HANH DONG, khong tat may. Tai nguyen dang chay VAN
  #     TINH TIEN. Don sach TRUOC khi park, dung sau.
  #   - Khong ap len management account - SCP khong bao gio ap len
  #     no. Dung tim cach park management.
  #
  # FullAWSAccess van gan o OU nay va khong sao ca: Deny tuong minh
  # luon thang Allow. Go no ra chi lam y do ro rang hon, va phai lam
  # bang tay vi Terraform khong quan ly attachment mac dinh cua AWS.
  ####################################

  stmt_suspended = [
    jsonencode({
      Sid      = "DenyAll"
      Effect   = "Deny"
      Action   = "*"
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

    suspended = {
      enabled     = try(var.enable_scp.suspended, true)
      description = "Dong bang account trong OU Suspended - chan moi hanh dong"
      statements  = local.stmt_suspended
      targets     = ["Suspended"]
    }
  }

  scp_enabled = { for k, v in local.scp_definitions : k => v if v.enabled }

  ########################################
  # GIAI TEN TARGET THANH OU ID
  #
  # Target o tren viet theo duong dan: "Workloads/Production". Do la
  # cach local.ou_ids danh khoa KHI ou_structure khai Production la OU
  # con cua Workloads.
  #
  # Nhung ou_structure la mot BIEN. Khai phang - Production nam thang
  # duoi root - thi khoa la "Production", va "Workloads/Production"
  # khong ton tai.
  #
  # Nen thu ca hai: duong dan day du truoc, roi doan cuoi.
  ########################################
  scp_target_id = {
    for t in distinct(flatten([for _, d in local.scp_enabled : d.targets])) :
    t => t == "ROOT" ? local.root_id : try(
      local.ou_ids[t],
      local.ou_ids[element(split("/", t), length(split("/", t)) - 1)],
      null
    )
  }

  scp_targets_unresolved = [for t, id in local.scp_target_id : t if id == null]

  # (policy, target) -> mot attachment
  scp_attachments = var.scp_dry_run ? {} : {
    for item in flatten([
      for name, def in local.scp_enabled : [
        for t in def.targets : {
          key    = "${name}|${t}"
          policy = name
          target = local.scp_target_id[t]
        }
      ]
    ]) : item.key => item if item.target != null
  }

  # Chinh sach BAT nhung khong gan duoc vao dau.
  #
  # Truoc day dieu nay xay ra IM LANG: `if item.target != null` loai
  # muc do khoi map, khong con dau vet. aws_organizations_policy van
  # duoc tao, console van thay chinh sach, va scp_summary van in ra
  # danh sach target NHU DA KHAI - trong khi khong co attachment nao.
  #
  # Da xay ra that: ou_structure khai phang, prod_guard nham
  # "Workloads/Production", va OU chua account production khong co
  # guardrail nao. Khong loi, khong canh bao, khong resource nao thieu
  # mot cach nhin thay duoc.
  scp_policies_orphan = var.scp_dry_run ? [] : [
    for name, def in local.scp_enabled : name
    if length([for t in def.targets : t if local.scp_target_id[t] != null]) == 0
  ]
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
# CHOT: KHONG CHO MOT SCP TON TAI MA KHONG GAN VAO DAU
#
# precondition chu khong phai check. Mot chinh sach khong gan vao dau
# khong phai "nen xem lai" - no la mot guardrail mo tren giay va
# khong ton tai trong thuc te, va moi thu khac deu bao rang no co.
########################################
resource "terraform_data" "scp_guard" {
  input = {
    orphan     = local.scp_policies_orphan
    unresolved = local.scp_targets_unresolved
  }

  lifecycle {
    precondition {
      condition = length(local.scp_policies_orphan) == 0
      error_message = join(" ", [
        "SCP dang BAT nhung khong gan duoc vao OU nao:",
        join(", ", local.scp_policies_orphan),
        "- chinh sach van duoc tao, console van thay no, va khong co gi bi chan.",
        "Target khong giai duoc:", join(", ", local.scp_targets_unresolved),
        ". Ten OU co that:", join(", ", sort(keys(local.ou_ids))),
        ". Sua targets trong scp_definitions cho khop var.ou_structure,",
        "hoac doi ou_structure cho khop targets.",
      ])
    }

    # Target hong le - chinh sach van con target khac nen khong thanh
    # mo coi. Van phai noi: mot OU dang le duoc bao ve thi khong.
    precondition {
      condition = length(local.scp_targets_unresolved) == 0
      error_message = join(" ", [
        "Target cua SCP khong giai duoc thanh OU ID:",
        join(", ", local.scp_targets_unresolved),
        ". OU do KHONG duoc chinh sach nao gan vao, va viec do khong",
        "hien ra o bat cu dau: aws_organizations_policy van duoc tao,",
        "scp_summary van in ten target nhu da khai.",
        "Ten OU co that:", join(", ", sort(keys(local.ou_ids))),
      ])
    }
  }
}

########################################
# OU KHONG DUOC SCP NAO GAN VAO
#
# check chu khong phai precondition: co OU khong can SCP rieng that -
# chung duoc phu boi SCP gan o ROOT. Nhung mot OU chua workload ma
# khong co guardrail nao ngoai ROOT thi phai duoc NHIN THAY, khong
# phai suy ra bang cach doc ba file.
#
# Truong hop that: ou_structure khai phang, "Workloads" ton tai nhung
# RONG, con Non-Production va Production - hai OU chua toan bo
# workload - khong nam trong targets cua network_lock. SCP do la thu
# chan tao IGW, tuc la thu giu cho moi duong ra Internet di qua
# account network. Thieu no thi ca thiet ke egress tap trung chi con
# la mot quy uoc.
########################################
check "moi_ou_deu_co_scp" {
  assert {
    condition = length([
      for name, id in local.ou_ids : name
      if !contains([for _, a in local.scp_attachments : a.target], id)
    ]) == 0

    error_message = join(" ", [
      "OU khong duoc SCP nao gan truc tiep:",
      join(", ", [
        for name, id in local.ou_ids : name
        if !contains([for _, a in local.scp_attachments : a.target], id)
      ]),
      ". Chung chi con SCP gan o ROOT (region_lock).",
      "Kiem lai targets trong local.scp_definitions co khop cay OU that khong -",
      "vi du network_lock nham \"Workloads\" trong khi account nam o",
      "Non-Production va Production la hai OU ngang hang, khong phai con.",
    ])
  }
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

########################################
# SUSPENDED - hai cach hong LANG LE
#
# Ca hai deu de OU Suspended ton tai ma KHONG dong bang gi ca. Nguy
# hiem hon la khong co OU: park-account.sh chay tron, bao thanh cong,
# va account van chay binh thuong trong mot OU ten "Suspended".
########################################

check "suspended_ou_is_actually_frozen" {
  assert {
    condition = (
      !contains(keys(var.ou_structure), "Suspended")
      || try(var.enable_scp.suspended, true)
    )

    error_message = join(" ", [
      "ou_structure co OU 'Suspended' nhung enable_scp.suspended = false.",
      "OU do se KHONG dong bang gi ca - account chuyen vao van chay",
      "binh thuong, va ten OU lam moi nguoi tuong nguoc lai.",
      "Bat enable_scp.suspended, hoac bo OU 'Suspended' khoi ou_structure.",
    ])
  }
}

check "suspended_not_silently_unattached" {
  assert {
    condition = (
      !contains(keys(var.ou_structure), "Suspended")
      || !try(var.enable_scp.suspended, true)
      || !var.scp_dry_run
    )

    error_message = join(" ", [
      "scp_dry_run = true nen SCP suspended duoc TAO nhung KHONG GAN",
      "vao OU nao. Account park vao Suspended luc nay van chay binh thuong.",
      "Tat scp_dry_run truoc khi dung park-account.sh.",
    ])
  }
}
