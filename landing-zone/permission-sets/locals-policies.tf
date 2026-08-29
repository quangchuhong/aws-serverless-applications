########################################
# CAC MANH POLICY DUNG CHUNG
#
# Nhac lai mot quy tac IAM quyet dinh cach doc file nay:
#   Deny tuong minh LUON THANG Allow, bat ke thu tu hay do cu the.
# Nen moi statement Deny o day la chan tuyet doi, khong the mo lai
# bang mot Allow o cho khac.
########################################

locals {

  ########################################
  # 1. EC2 tru network API va security API
  #
  # IAM khong co cu phap \"cho phep ec2:* TRU nhom X\". Phai
  # Allow ec2:* roi Deny liet ke tay.
  #
  # VA CHAM VAN HANH THAT: chan ca *SecurityGroup* thi server-admin
  # khong launch duoc EC2 hay tao ELB moi, vi hai viec do gan nhu
  # luon can tao SG.
  #
  # Can bang duoc chon o day: CHO tao/xoa SG, CAM sua rule
  # (Authorize*/Revoke*). Tao duoc vo container rong, nhung khong tu
  # mo duoc port - viec mo port thuoc ve network/security team.
  ########################################
  deny_ec2_network = {
    Sid    = "DenyEc2NetworkApis"
    Effect = "Deny"
    Action = [
      "ec2:*Vpc*",
      "ec2:*Subnet*",
      "ec2:*Route*",
      "ec2:*Gateway*",
      "ec2:*TransitGateway*",
      "ec2:*Vpn*",
      "ec2:*Peering*",
      "ec2:*NetworkAcl*",
      "ec2:*DhcpOptions*",
      "ec2:*Address*", # Elastic IP
      "ec2:*ClientVpn*",
      "ec2:*CarrierGateway*",
      "ec2:*PrefixList*",
      "ec2:*TrafficMirror*",
    ]
    Resource = "*"
  }

  deny_ec2_security = {
    Sid    = "DenyEc2SecurityGroupRuleChanges"
    Effect = "Deny"
    Action = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:ModifySecurityGroupRules",
    ]
    Resource = "*"
  }

  ########################################
  # 2. Chot PassRole
  #
  # Duong leo thang quyen quan trong nhat trong ca bang:
  #
  #   server-admin -> tao Lambda, gan execution role = mot role admin
  #                -> invoke -> chay code voi quyen admin
  #
  # SageMaker con thang hon: notebook instance la shell that.
  # EMR: cluster launch EC2 voi instance profile.
  # CloudFormation: deploy stack voi service role admin.
  #
  # Chan bang cach chi cho pass role co TIEN TO da dinh, va chi
  # pass duoc SANG DUNG SERVICE can thiet.
  ########################################

  passrole_workload = {
    Sid      = "PassRoleOnlyWorkloadRoles"
    Effect   = "Allow"
    Action   = "iam:PassRole"
    Resource = "arn:aws:iam::*:role/${lookup(var.passrole_prefixes, "workload", "lz-workload-")}*"
    Condition = {
      StringEquals = {
        "iam:PassedToService" = [
          "lambda.amazonaws.com",
          "ec2.amazonaws.com",
          "ecs-tasks.amazonaws.com",
          "ecs.amazonaws.com",
          "eks.amazonaws.com",
          "states.amazonaws.com",
          "events.amazonaws.com",
          "apigateway.amazonaws.com",
          "cloudformation.amazonaws.com",
          "ssm.amazonaws.com",
          "application-autoscaling.amazonaws.com",
        ]
      }
    }
  }

  passrole_analytics = {
    Sid      = "PassRoleOnlyAnalyticsRoles"
    Effect   = "Allow"
    Action   = "iam:PassRole"
    Resource = "arn:aws:iam::*:role/${lookup(var.passrole_prefixes, "analytics", "lz-analytics-")}*"
    Condition = {
      StringEquals = {
        "iam:PassedToService" = [
          "sagemaker.amazonaws.com",
          "glue.amazonaws.com",
          "elasticmapreduce.amazonaws.com",
          "lakeformation.amazonaws.com",
          "athena.amazonaws.com",
          "redshift.amazonaws.com",
          "lambda.amazonaws.com",
          "firehose.amazonaws.com",
        ]
      }
    }
  }

  # Quyen IAM toi thieu de doc/tao service-linked role. Khong co
  # dong nay thi rat nhieu service khong khoi tao duoc lan dau.
  iam_minimal_for_workload = {
    Sid    = "IamReadAndServiceLinkedRoles"
    Effect = "Allow"
    Action = [
      "iam:Get*",
      "iam:List*",
      "iam:CreateServiceLinkedRole",
      "iam:CreateInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:DeleteInstanceProfile",
    ]
    Resource = "*"
  }

  # Chan tuyet doi moi duong sua IAM khac. Dat cung cho tat ca set
  # KHONG phai security-admin / account-admin.
  deny_iam_writes = {
    Sid    = "DenyIamWritesOutsideSecurityDomain"
    Effect = "Deny"
    Action = [
      "iam:CreateUser",
      "iam:CreateRole",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
      "iam:AttachUserPolicy",
      "iam:AttachRolePolicy",
      "iam:AttachGroupPolicy",
      "iam:PutUserPolicy",
      "iam:PutRolePolicy",
      "iam:PutGroupPolicy",
      "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary",
      "iam:CreatePolicyVersion",
      "iam:SetDefaultPolicyVersion",
    ]
    Resource = "*"
  }

  ########################################
  # 3. Chan doc du lieu cho cac set operator / auditor
  #
  # Day la khac biet quan trong nhat so voi AWS ReadOnlyAccess.
  # Chi tiet o doc 19 muc 3.1.
  #
  # KHONG chan logs:* - app team phai doc duoc log cua minh o prod.
  ########################################
  deny_data_plane = {
    Sid    = "DenyDataPlaneReads"
    Effect = "Deny"
    Action = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetObjectTorrent",
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:PartiQLSelect",
      "secretsmanager:GetSecretValue",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "kms:Decrypt",
      "kms:GenerateDataKey*",
      "lambda:GetFunction", # tra ve pre-signed URL tai duoc ca source
      "athena:GetQueryResults",
      "redshift-data:GetStatementResult",
      "sqs:ReceiveMessage",
    ]
    Resource = "*"
  }

  ########################################
  # 4. Chan truy cap phien dieu khien (interactive) cho operator
  #
  # SSM Session Manager = shell that tren EC2 -> quyen cua instance
  # profile tro thanh quyen cua nguoi dung. Khong phai read-only.
  ########################################
  deny_interactive_access = {
    Sid    = "DenyInteractiveShellForOperators"
    Effect = "Deny"
    Action = [
      "ssm:StartSession",
      "ssm:SendCommand",
      "ssm:CreateAssociation",
      "ssm:StartAutomationExecution",
      "ec2-instance-connect:*",
      "ec2:GetPasswordData",
      "sagemaker:CreatePresignedNotebookInstanceUrl",
      "sagemaker:CreatePresignedDomainUrl",
    ]
    Resource = "*"
  }

  ########################################
  # 5. Lake Formation - he thong phan quyen SONG SONG voi IAM
  #
  # lakeformation:PutDataLakeSettings cho phep tu dat minh lam
  # Data Lake Administrator, roi GrantPermissions cho chinh minh
  # tren MOI bang Glue catalog -> doc toan bo data lake, bo qua
  # bucket policy cua S3.
  #
  # Nghia la lakeformation:* ~= quyen doc toan bo du lieu, bat ke
  # ban siet S3 the nao.
  #
  # Ba action nay tach ra thanh set rieng lz-datalake-admin.
  ########################################
  deny_lakeformation_grants = {
    Sid    = "DenyLakeFormationSelfGrant"
    Effect = "Deny"
    Action = [
      "lakeformation:PutDataLakeSettings",
      "lakeformation:GrantPermissions",
      "lakeformation:BatchGrantPermissions",
      "lakeformation:RegisterResource",
    ]
    Resource = "*"
  }

  ########################################
  # 6. Boundary bat buoc cho lz-security-admin
  #
  # Khong co dong nay thi lz-security-admin TUONG DUONG
  # lz-account-admin: IAM full quyen = tu tao role admin roi assume.
  #
  # LUU Y CU PHAP: phai dung ArnNotLike chu khong phai StringNotEquals.
  # StringNotEquals so sanh CHINH XAC, khong hieu dau * trong ARN,
  # nen dieu kien se khong bao gio khop va statement thanh vo dung.
  #
  # ---------------------------------------------------------------
  # VI SAO HAI STATEMENT NAY LA HAI LOCAL RIENG, KHONG PHAI MOT LIST
  #
  # Ban dau chung nam trong mot list dieu kien:
  #   var.enforce_security_admin_boundary ? [stmt1, stmt2] : []
  #
  # Terraform tu choi ngay o buoc kiem kieu, KE CA khi bien la false:
  #   Inconsistent conditional result types
  #   The 'true' tuple has length 2, but the 'false' tuple has length 0.
  #
  # Ly do: stmt1 co thuoc tinh Condition, stmt2 khong. Hai object khac
  # bo thuoc tinh -> khong quy duoc ve list(object) chung -> ket qua la
  # TUPLE. Tuple do dai 2 va tuple do dai 0 la hai kieu khac nhau, nen
  # hai nhanh cua ?: khong bao gio thong nhat duoc.
  #
  # Dung chinh cai bay ma dau permission-sets.tf da canh bao.
  #
  # Cach chua: bo dieu kien o day. Viec bat/tat da do local.guard_bound
  # trong permission-sets.tf lo - no tra ve list<string> ten statement,
  # dong nhat kieu nen khong bao gio vuong. Mot cong tac o mot cho.
  # ---------------------------------------------------------------

  deny_create_without_boundary = {
    Sid    = "DenyCreatePrincipalWithoutBoundary"
    Effect = "Deny"
    Action = [
      "iam:CreateRole",
      "iam:CreateUser",
    ]
    Resource = "*"
    Condition = {
      ArnNotLike = {
        "iam:PermissionsBoundary" = "arn:aws:iam::*:policy/${var.permission_boundary_name}"
      }
    }
  }

  deny_boundary_tampering = {
    Sid    = "DenyRemovingOrEditingTheBoundaryItself"
    Effect = "Deny"
    Action = [
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary",
      "iam:CreatePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
    ]
    Resource = "arn:aws:iam::*:policy/${var.permission_boundary_name}"
  }

  ########################################
  # 7. Bao ve nen tang - dat cho MOI set tru account-admin
  #
  # Khong ai duoc pha chinh co che kiem soat:
  #   - roi khoi Organization
  #   - tat CloudTrail / GuardDuty / Config
  #   - sua permission set cua chinh minh
  ########################################
  deny_guardrails = {
    Sid    = "DenyTamperingWithGuardrails"
    Effect = "Deny"
    Action = [
      "organizations:LeaveOrganization",
      "organizations:DeleteOrganization",
      "organizations:RemoveAccountFromOrganization",
      "cloudtrail:StopLogging",
      "cloudtrail:DeleteTrail",
      "cloudtrail:UpdateTrail",
      "guardduty:DeleteDetector",
      "guardduty:DisassociateFromMasterAccount",
      "config:DeleteConfigurationRecorder",
      "config:StopConfigurationRecorder",
      "config:DeleteDeliveryChannel",
      "sso:Delete*",
      "sso:Detach*",
      "sso:Put*",
      "sso:Update*",
      "account:CloseAccount",
    ]
    Resource = "*"
  }

  ########################################
  # BUCKET BANG CHUNG - lop bao ve thu hai
  #
  # VI SAO CAN, KHI DA TACH PHAM VI:
  #
  # Pham vi la lop thu nhat - lz-server-admin gio chi vao account
  # workload, khong vao log archive nua. Day la lop thu hai, cho truong
  # hop ai do sau nay khai lai scope = "all", hoac them mot account loi
  # ma quen dua vao core_accounts.
  #
  # Mot lop thi mot lan sua nham la mat. Hai lop thi phai sai o hai cho
  # khac nhau cung luc.
  #
  # deny_guardrails chan API cua CloudTrail va Config. Statement nay
  # chan viec xoa CHINH FILE - thu ma DeleteTrail khong dung toi.
  #
  # RESOURCE PHAI CU THE, KHONG DUOC "*".
  #
  # Deny s3:DeleteBucket tren "*" se chan ca viec xoa bucket hop le
  # trong account workload - lz-server-admin quan S3 o do la dung viec.
  # Nen statement nay chi neu dich danh bon ARN cua hai bucket bang
  # chung.
  #
  # core_accounts.log_archive de rong thi khong rap duoc ten bucket va
  # statement KHONG duoc sinh ra. check "core_accounts_declared" o
  # organizations.tf canh bao truong hop do.
  #
  # ---------------------------------------------------------------
  # TRAN CUA LOP NAY - KHONG PHAI BAO VE TUYET DOI
  #
  # Statement duoc gan theo deny_guardrails. lz-account-admin co
  # statements = [] - khong co inline policy nao, chi
  # AdministratorAccess - nen KHONG nhan deny nay, va van o scope
  # "all". Nhom lz-platform-admins do do van co s3:* trong account
  # log archive.
  #
  # Do la CO Y, khong phai sot: lz-account-admin la duong break-glass,
  # va phai co ai do van hanh duoc account log archive. Chan no thi
  # chi con credential root.
  #
  # Nen doc lop nay dung pham vi cua no: no chan cac set VAN HANH
  # (compute, database, ung dung, phan tich) cham vao bang chung.
  # No KHONG chan duong quan tri nen tang. Muon chan ca duong do thi
  # phai tach mot set quan tri rieng cho log archive voi group rieng
  # - mot quyet dinh khac, khong phai mot dong them vao day.
  # ---------------------------------------------------------------
  ########################################
  evidence_bucket_arns = var.core_accounts.log_archive == "" ? [] : [
    "arn:aws:s3:::${var.project}-cloudtrail-${var.core_accounts.log_archive}",
    "arn:aws:s3:::${var.project}-cloudtrail-${var.core_accounts.log_archive}/*",
    "arn:aws:s3:::${var.project}-config-snapshots-${var.core_accounts.log_archive}",
    "arn:aws:s3:::${var.project}-config-snapshots-${var.core_accounts.log_archive}/*",
  ]

  deny_evidence_deletion = length(local.evidence_bucket_arns) == 0 ? [] : [{
    Sid    = "DenyDeletingAuditEvidence"
    Effect = "Deny"
    Action = [
      # Xoa file
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",

      # Xoa ca bucket - nhanh hon xoa tung file
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",

      # Tat versioning roi xoa: khong con version cu de khoi phuc
      "s3:PutBucketVersioning",

      # Dat lifecycle het han sau 1 ngay - xoa ma khong goi lenh xoa nao
      "s3:PutLifecycleConfiguration",

      # Go Object Lock neu sau nay co bat
      "s3:PutObjectRetention",
      "s3:PutObjectLegalHold",
      "s3:BypassGovernanceRetention",
    ]
    Resource = local.evidence_bucket_arns
  }]
}
