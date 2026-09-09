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
      # Y DINH: chi bon khoa pipeline thuc su chay, khong phai ca
      # bucket - bucket do giu state cua MOI layer, ke ca tf-backend
      # va organization.
      #
      # NHUNG DOC TIEP TRUOC KHI TIN DONG TREN: statement
      # "VendingVaBaseline" ben duoi cap `s3:*` tren `*`. IAM la HOP
      # cua cac Allow, nen mot statement hep khong han che duoc mot
      # statement rong trong CUNG mot policy. Thuc te CodeBuild ghi
      # duoc MOI khoa trong bucket state.
      #
      # De lai statement nay vi no van la tai lieu ve pham vi DUNG,
      # va vi cach chua that su la thu hep `s3:*` - viec do can biet
      # chinh xac bon layer tao nhung bucket nao (Config delivery
      # channel, flow log...) va se lam rieng.
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

      ####################################
      # BANG KHOA STATE
      #
      # Backend S3 giu khoa trong DynamoDB. Thieu quyen o day KHONG
      # lam `terraform init` hong - init khong lay khoa - nen loi chi
      # hien ra o `plan`, sau khi state da doc duoc va moi thu truoc
      # do deu xanh:
      #
      #   Error: Error acquiring the state lock
      #   Error message: operation error DynamoDB: PutItem, ...
      #
      # Ba dong cua thong bao noi ve DynamoDB va ZERO dong noi ve
      # quyen, nen no doc nhu mot khoa dang bi ai do giu.
      #
      # DeleteItem la CAN, khong phai cho du: no vua de nha khoa sau
      # moi lan chay, vua de `terraform force-unlock` go duoc mot khoa
      # con sot lai khi build bi huy giua chung. Thieu no thi lan chay
      # dau tien bi huy se khoa layer do lai vinh vien.
      ####################################
      # Khai o cuoi, trong mot nhanh co dieu kien: state_lock_table de
      # rong nghia la lock_mode = "s3" (dung lockfile), va luc do mot
      # ARN "table/" khong ten se lam AWS tu choi ca policy.

      ####################################
      # DOC terraform.tfvars - CHI DOC
      #
      # Khong co PutObject: pipeline khong duoc tu sua cau hinh cua
      # chinh no. Doi tfvars la viec cua nguoi, qua ./push-tfvars.sh
      # tu may co credential rieng.
      ####################################
      {
        Sid      = "DocTfvars"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.tfvars[0].arn}/tfvars/*"]
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

          # `sts:AssumeRole` CO Y khong nam o day.
          #
          # Truoc day no o trong danh sach nay voi Resource = ["*"],
          # va nhu vay statement "SangAccountMang" ben duoi - cai
          # khai DUNG MOT role - khong han che duoc gi ca. No doc nhu
          # mot rang buoc ma khong phai rang buoc.
          #
          # Gio muon nhay sang bat ky account nao thi phai them ARN
          # vao SangAccountMang, va them o do la mot dong hien ra
          # trong code review.
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
      {
        # Khong tu sua CAU HINH cua chinh minh.
        #
        # DENY, khong phai "khong khai Allow": `s3:*` tren `*` o
        # VendingVaBaseline da cap ghi roi. Chi mot Deny tuong minh
        # moi that su chan - Deny thang Allow trong moi truong hop.
        #
        # Neu thieu no: mot lan chay co the sua tfvars cua chinh no
        # roi lan chay sau doc cau hinh moi do. Cong duyet van chan
        # apply, nhung thu duoc duyet la thu tinh tren cau hinh khong
        # ai viet.
        Sid    = "KhongGhiDeCauHinhCuaChinhMinh"
        Effect = "Deny"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
          "s3:PutBucketPolicy",
          "s3:DeleteBucketPolicy",
          "s3:PutBucketVersioning",
        ]
        Resource = [
          aws_s3_bucket.tfvars[0].arn,
          "${aws_s3_bucket.tfvars[0].arn}/*",
        ]
      },
      ],

      var.state_lock_table == "" ? [] : [{
        Sid    = "KhoaState"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/${var.state_lock_table}",
        ]
      }],

      ####################################
      # NHAY SANG ACCOUNT KHAC - LIET KE TUNG ROLE
      #
      # Mot statement, mot danh sach ARN cu the. Khong `Resource =
      # ["*"]`: voi `sts:AssumeRole` thi `*` nghia la assume duoc MOI
      # role trong to chuc ma tin no - trong do co
      # OrganizationAccountAccessRole, tuc admin day du o moi account.
      #
      # Them mot account dich = them mot dong o tfvars, hien ra trong
      # code review. Do la ca muc dich.
      ####################################
      length(local.assume_targets) == 0 ? [] : [{
        Sid      = "SangAccountKhac"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = local.assume_targets
      }]
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
