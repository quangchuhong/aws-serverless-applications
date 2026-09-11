########################################
# QUYEN
#
# Nguyen tac o day: DOC RONG, GHI HEP.
#
# `-target` gioi han APPLY vao dung hai resource SCP. Nhung `plan` thi
# REFRESH TOAN BO state cua layer - gom cay OU, delegated
# administrator, tag policy. Nen role nay bat buoc doc duoc ca chung,
# du khong bao gio duoc sua.
#
# Do la mot bat doi xung de doc nham theo chieu nguy hiem: nhin danh
# sach Action thay "organizations:Describe*, List*" roi ket luan "role
# nay chi doc" - trong khi no co UpdatePolicy va AttachPolicy. Va nhin
# nguoc lai cung nham: thay UpdatePolicy roi ket luan no sua duoc cay
# OU.
#
# Ranh gioi that nam o CHO GHI, va no duoc liet ke tung dong duoi day.
########################################

resource "aws_iam_role" "codebuild" {
  count = local.enabled ? 1 : 0

  name = "${local.name}-codebuild"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  count = local.enabled ? 1 : 0

  name = "ops"
  role = aws_iam_role.codebuild[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "GhiLog"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.name}*"
      },

      ####################################
      # STATE
      #
      # Bon thu, khong phai mot - va thieu bat ky cai nao cung cho mot
      # loi khong nhac gi toi state:
      #
      #   1. Object cua dung nhung layer trong layer_keys
      #   2. ListBucket tren bucket (init can, de biet object co ton
      #      tai khong)
      #   3. KMS key neu bucket ma hoa bang KMS
      #   4. Bang khoa DynamoDB - init KHONG lay khoa, nen thieu quyen
      #      nay chi lo ra o buoc plan. Loi 99.
      ####################################
      {
        Sid      = "DocGhiState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [for _, k in var.layer_keys : "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket}/${k}"]
      },
      {
        Sid      = "LietKeBucketState"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket}"
      },

      ####################################
      # KHO tfvars - CHI DOC
      #
      # Pipeline khong bao gio duoc GHI vao kho tfvars. Neu no ghi
      # duoc thi no tu doi duoc dau vao cua chinh minh, va moi phep
      # review tren git tro thanh trang tri.
      ####################################
      {
        Sid      = "DocTfvars"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.tfvars_bucket}/tfvars/*"
      },
      {
        Sid      = "LietKeKhoTfvars"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.tfvars_bucket}"
      },
      {
        Sid    = "TuChoiGhiVaoKhoTfvars"
        Effect = "Deny"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
          "s3:PutBucketPolicy",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:s3:::${var.tfvars_bucket}",
          "arn:${data.aws_partition.current.partition}:s3:::${var.tfvars_bucket}/*",
        ]
      },

      ####################################
      # KMS - cho ca state va artifact
      ####################################
      {
        Sid    = "KmsChoStateVaArtifact"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
          "kms:ReEncrypt*",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = [
              "s3.${var.region}.amazonaws.com",
              "dynamodb.${var.region}.amazonaws.com",
            ]
          }
        }
      },

      ####################################
      # ORGANIZATIONS - DOC RONG
      #
      # plan refresh toan bo state cua layer organization, nen phai doc
      # duoc cay OU, delegated admin va tag policy - du khong sua.
      ####################################
      {
        Sid    = "DocToChuc"
        Effect = "Allow"
        Action = [
          "organizations:Describe*",
          "organizations:List*",
        ]
        Resource = "*"
      },

      ####################################
      # ORGANIZATIONS - GHI HEP
      #
      # DAY LA RANH GIOI THAT CUA PIPELINE NAY. Chin action, va chung
      # chi cham vao POLICY:
      #
      #   khong CreateAccount        khong tao account
      #   khong MoveAccount          khong doi OU cua account
      #   khong CreateOrganizationalUnit / Update / Delete
      #                              khong sua cay OU
      #   khong RegisterDelegatedAdministrator
      #                              khong cap quyen cho account khac
      #   khong EnablePolicyType / DisablePolicyType
      #                              khong tat ca loai policy - mot
      #                              lenh do go SACH moi SCP cung luc
      #
      # Loai cuoi dang chu y nhat: DisablePolicyType khong xoa policy
      # nao, no chi lam chung thoi co hieu luc. Console van hien day du
      # danh sach SCP, va khong con cai nao chan gi.
      ####################################
      {
        Sid    = "GhiChinhSach"
        Effect = "Allow"
        Action = [
          "organizations:CreatePolicy",
          "organizations:UpdatePolicy",
          "organizations:DeletePolicy",
          "organizations:AttachPolicy",
          "organizations:DetachPolicy",
          "organizations:TagResource",
          "organizations:UntagResource",
        ]
        Resource = "*"
      },
      {
        Sid    = "TuChoiViecNgoaiPhamVi"
        Effect = "Deny"
        Action = [
          "organizations:CreateAccount",
          "organizations:CloseAccount",
          "organizations:MoveAccount",
          "organizations:RemoveAccountFromOrganization",
          "organizations:CreateOrganizationalUnit",
          "organizations:UpdateOrganizationalUnit",
          "organizations:DeleteOrganizationalUnit",
          "organizations:EnablePolicyType",
          "organizations:DisablePolicyType",
          "organizations:RegisterDelegatedAdministrator",
          "organizations:DeregisterDelegatedAdministrator",
          "organizations:LeaveOrganization",
          "organizations:DeleteOrganization",
        ]
        Resource = "*"
      },
      ],

      ####################################
      # BANG KHOA STATE
      #
      # Chi them khi co bang. `init` KHONG lay khoa, nen thieu quyen
      # nay chi lo ra o buoc plan - voi mot loi noi ve DynamoDB:PutItem
      # ma khong nhac gi toi state. Loi 99.
      ####################################
      var.state_lock_table == "" ? [] : [{
        Sid    = "KhoaState"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/${var.state_lock_table}"
      }],

      # Bao drift. Chi Publish, dung topic da khai.
      var.drift_topic_arn == "" ? [] : [{
        Sid      = "BaoDrift"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.drift_topic_arn
    }])
  })
}

########################################
# ARTIFACT - CodeBuild doc/ghi qua CodePipeline
########################################

resource "aws_iam_role_policy" "codebuild_artifacts" {
  count = local.enabled ? 1 : 0

  name = "artifacts"
  role = aws_iam_role.codebuild[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
      Resource = [
        aws_s3_bucket.artifacts[0].arn,
        "${aws_s3_bucket.artifacts[0].arn}/*",
      ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey",
          "kms:DescribeKey", "kms:ReEncrypt*",
        ]
        Resource = aws_kms_key.artifacts[0].arn
    }]
  })
}

########################################
# ROLE CUA PIPELINE
########################################

resource "aws_iam_role" "pipeline" {
  count = local.enabled ? 1 : 0

  name = "${local.name}-pipeline"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "pipeline" {
  count = local.enabled ? 1 : 0

  name = "ops"
  role = aws_iam_role.pipeline[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning"]
        Resource = [
          aws_s3_bucket.artifacts[0].arn,
          "${aws_s3_bucket.artifacts[0].arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey",
          "kms:DescribeKey", "kms:ReEncrypt*",
        ]
        Resource = aws_kms_key.artifacts[0].arn
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = aws_codebuild_project.terraform[0].arn
      },
      ],
      var.source_type == "codecommit" ? [{
        Effect = "Allow"
        Action = [
          "codecommit:GetBranch",
          "codecommit:GetCommit",
          "codecommit:GetRepository",
          "codecommit:UploadArchive",
          "codecommit:GetUploadArchiveStatus",
          "codecommit:CancelUploadArchive",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:codecommit:${var.region}:${data.aws_caller_identity.current.account_id}:${var.repository_name}"
    }] : [])
  })
}

########################################
# ROLE CHO EVENTBRIDGE
########################################

resource "aws_iam_role" "events" {
  count = local.enabled ? 1 : 0

  name = "${local.name}-events"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "events" {
  count = local.enabled ? 1 : 0

  name = "khoi-chay"
  role = aws_iam_role.events[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "codepipeline:StartPipelineExecution"
        Resource = aws_codepipeline.ops[0].arn
      },
      {
        Effect   = "Allow"
        Action   = "codebuild:StartBuild"
        Resource = aws_codebuild_project.drift[0].arn
      },
    ]
  })
}
