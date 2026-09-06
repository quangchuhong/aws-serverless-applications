########################################
# HAI ROLE, HAI VIEC KHAC NHAU
#
#   pipeline   dieu phoi: doc nguon, goi CodeBuild, gui thu duyet.
#              KHONG tao duoc resource ha tang nao.
#   codebuild  chay terraform: day moi la role co quyen.
#
# Tach ra vi mot ly do doc duoc trong CloudTrail: moi thay doi ha
# tang deu mang danh tinh cua codebuild role, con pipeline role chi
# xuat hien o cac lenh dieu phoi. Gop lam mot thi khong con phan biet
# duoc "pipeline chay" voi "pipeline tao ra cai gi".
########################################

########################################
# 1. ROLE DIEU PHOI
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

  tags = { Name = "${local.name}-pipeline" }
}

resource "aws_iam_role_policy" "pipeline" {
  count = local.enabled ? 1 : 0

  name = "dieu-phoi"
  role = aws_iam_role.pipeline[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "Artifact"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:GetBucketLocation",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.artifacts[0].arn,
          "${aws_s3_bucket.artifacts[0].arn}/*",
        ]
      },
      {
        Sid      = "MaHoaArtifact"
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = [aws_kms_key.artifacts[0].arn]
      },
      {
        Sid    = "GoiCodeBuild"
        Effect = "Allow"
        Action = ["codebuild:StartBuild", "codebuild:BatchGetBuilds", "codebuild:StopBuild"]
        Resource = compact([
          aws_codebuild_project.terraform[0].arn,
          aws_codebuild_project.lint[0].arn,
          try(aws_codebuild_project.cho_attachment[0].arn, ""),
        ])
      },
      {
        Sid      = "GuiThuDuyet"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.approval[0].arn]
      },
      ],
      var.source_type == "codecommit" ? [{
        Sid    = "DocNguon"
        Effect = "Allow"
        Action = [
          "codecommit:GetBranch",
          "codecommit:GetCommit",
          "codecommit:GetRepository",
          "codecommit:GetUploadArchiveStatus",
          "codecommit:UploadArchive",
          "codecommit:CancelUploadArchive",
        ]
        Resource = ["arn:${data.aws_partition.current.partition}:codecommit:${var.region}:${data.aws_caller_identity.current.account_id}:${var.repository_name}"]
        }] : [{
        Sid      = "DocNguonS3"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = ["arn:${data.aws_partition.current.partition}:s3:::${var.source_bucket}/*"]
    }])
  })
}

########################################
# 2. ROLE CHAY TERRAFORM
#
# Day la role co quyen. Ba nhom, va nhom thu ba la nhom dang doc ky.
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

  tags = { Name = "${local.name}-codebuild" }
}

resource "aws_iam_role_policy" "codebuild" {
  count = local.enabled ? 1 : 0

  name = "chay-terraform"
  role = aws_iam_role.codebuild[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "Log"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.name}*"]
      },
      {
        Sid    = "Artifact"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.artifacts[0].arn,
          "${aws_s3_bucket.artifacts[0].arn}/*",
        ]
      },
      {
        Sid      = "MaHoaArtifact"
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = [aws_kms_key.artifacts[0].arn]
      },

      ####################################
      # STATE - HEP TOI TUNG KHOA
      #
      # Khong cap ca bucket. Bucket do giu state cua MOI layer trong
      # landing zone, ke ca tf-backend va organization. Pipeline nay
      # chi duoc cham vao bon khoa no thuc su chay.
      #
      # ListBucket phai co dieu kien s3:prefix, va prefix do phai phu
      # het cac khoa - neu khong `terraform init` bao 403 tren mot key
      # CHUA TON TAI (loi 85 doc 22) va thong bao khong nhac gi toi
      # prefix.
      ####################################
      {
        Sid      = "DocGhiState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = local.state_object_arns
      },
      {
        Sid      = "ListState"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = ["arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket}"]
      },
      {
        Sid    = "MaHoaState"
        Effect = "Allow"
        Action = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        # Khoa cua bucket state do layer tf-backend quan, khong phai
        # layer nay - nen khong tham chieu ARN cu the duoc.
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "kms:ViaService" = "s3.${var.region}.amazonaws.com"
          }
        }
      },

      ####################################
      # QUYEN TAO RESOURCE O CHINH ACCOUNT MANAGEMENT
      #
      # Bon layer chay o day tao: account, StackSet, Config, Security
      # Hub, Identity Center assignment, SCP.
      #
      # KHONG co iam:CreateUser va KHONG co iam:CreateAccessKey. Mot
      # pipeline khong bao gio can hai thu do, va chung la thu dau
      # tien mot phien bi chiem se dung.
      ####################################
      {
        Sid    = "VendingVaBaseline"
        Effect = "Allow"
        Action = [
          "organizations:*",
          "cloudformation:*",
          "config:*",
          "securityhub:*",
          "guardduty:*",
          "sso:*",
          "sso-directory:*",
          "identitystore:*",
          "sns:*",
          "logs:*",
          "cloudwatch:*",
          "lambda:*",
          "events:*",
          "ram:*",
          "sts:GetCallerIdentity",
          "sts:AssumeRole",
          "ec2:Describe*",
          "s3:*",
          "kms:*",
          "codecommit:GitPull",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "IamHepPhamVi"
        Effect = "Allow"
        Action = [
          "iam:GetRole", "iam:CreateRole", "iam:DeleteRole", "iam:PassRole",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:TagRole", "iam:UntagRole", "iam:UpdateAssumeRolePolicy",
          "iam:CreateServiceLinkedRole",
          "iam:GetAccountPasswordPolicy", "iam:UpdateAccountPasswordPolicy",
        ]
        Resource = ["*"]
      },
      {
        # Khong tu sua chinh minh. Cung ly do voi role ben layer
        # network: mot phien bi chiem se noi rong quyen roi o lai.
        Sid    = "KhongTuSuaChinhMinh"
        Effect = "Deny"
        Action = [
          "iam:UpdateAssumeRolePolicy",
          "iam:PutRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:DeleteRole",
        ]
        Resource = [
          aws_iam_role.codebuild[0].arn,
          aws_iam_role.pipeline[0].arn,
        ]
      },
      ],

      ####################################
      # NHAY SANG ACCOUNT MANG - chi MOT role, khai tuong minh
      ####################################
      local.network_on ? [{
        Sid      = "SangAccountMang"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = [var.network_deploy_role_arn]
      }] : []
    )
  })
}

output "codebuild_role_arn" {
  description = <<-EOT
    Dan vao pipeline_trusted_role_arns cua landing-zone/network.

    Hai layer tro vao nhau, nen thu tu apply lan dau la:
      1. layer nay voi network_deploy_role_arn = ""   -> lay ARN nay
      2. layer network voi pipeline_trusted_role_arns = [ARN do]
         -> lay pipeline_deploy_role_arn
      3. layer nay lan nua, dien network_deploy_role_arn
  EOT
  value       = local.enabled ? aws_iam_role.codebuild[0].arn : ""
}
