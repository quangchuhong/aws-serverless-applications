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
      ],

      ####################################
      # QUYEN CUA DICH VU - DO CALLER TRUYEN VAO
      #
      # Day la RANH GIOI THAT cua tung pipeline, va no KHAC NHAU o moi
      # pipeline nen no khong the nam trong module:
      #
      #   pipeline SCP       organizations:CreatePolicy, AttachPolicy...
      #   pipeline cloudops  config:*, ssoadmin:*, route53:*,
      #                      networkfirewall:*, va sts:AssumeRole sang
      #                      ba account khac
      #
      # Truyen tu caller nghia la ranh gioi ghi nam CANH danh sach stage,
      # trong cung mot file - dung cho nguoi review nhin. Neu no nam
      # trong module thi moi pipeline se dung chung mot tap quyen, va tap
      # do se la HOP cua moi thu tung can.
      #
      # var.quyen_dich_vu    Allow - thu pipeline nay duoc ghi
      # var.tu_choi_dich_vu  Deny  - thu no KHONG duoc ghi, viet ro
      #
      # Vi sao can ca hai chu khong chi Allow hep: Deny THANG Allow, nen
      # mot Deny viet ro van chan duoc ke ca khi mot policy khac gan vao
      # cung role mo rong hon. Va no doc duoc: mot nguoi doc Allow khong
      # biet duoc thu gi CO Y khong cho.
      ####################################
      ####################################
      # STATE CUA LAYER KHAC - CHI GetObject
      #
      # KHONG PutObject, khong DeleteObject. Pipeline doc state cua layer
      # khac de lay output; no khong bao gio duoc ghi vao do. Tach khoi
      # DocGhiState co chu dich: gop lai se cap quyen GHI tren state cua
      # layer khac, va mot lan apply nham o day lam layer kia mat state.
      #
      # LA MOT DOI SO concat RIENG, khong nam trong danh sach literal:
      # khi state_chi_doc rong thi Resource se la [], va IAM TU CHOI CA
      # POLICY voi mot loi ve dinh dang ARN - khong noi gi ve bien nao.
      ####################################
      length(var.state_chi_doc) == 0 ? [] : [{
        Sid      = "DocStateCuaLayerKhac"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = [for k in var.state_chi_doc : "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket}/${k}"]
      }],

      var.quyen_dich_vu,
      var.tu_choi_dich_vu,

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
      local.drift_topic == "" ? [] : [{
        Sid      = "BaoDrift"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = local.drift_topic
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
      ####################################
      # HAI PROJECT, LIET KE CA HAI
      #
      # Thieu mot cai o day KHONG hong luc apply - no hong luc pipeline
      # chay, va thong bao la AccessDenied tren StartBuild. Mot stage
      # moi them ma quen dong nay se doc nhu la pipeline bi hong quyen,
      # chu khong nhu la mot dong con thieu.
      #
      # Liet ke thay vi dung "*" tren moi project: role nay khong can
      # khoi duoc bat ky build nao khac trong account.
      ####################################
      {
        Effect = "Allow"
        Action = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        # compact() bo phan tu rong: project catalog khong ton tai khi
        # pipeline nay khong co catalog nao. Liet ke mot ARN rong se lam
        # IAM tu choi ca policy voi mot loi ve dinh dang ARN.
        Resource = compact([
          aws_codebuild_project.terraform[0].arn,
          try(aws_codebuild_project.catalog[0].arn, ""),
        ])
      },
      ],

      ####################################
      # BAO CO VIEC CAN DUYET
      #
      # HAI PHIA phai mo: cai nay (IAM cua role pipeline) va topic policy
      # o approval.tf. Mot phia mo mot minh thi KHONG co loi nao ca -
      # pipeline chi lang le khong gui thu, va cong duyet treo o do cho
      # toi khi het gio 7 ngay. Cung khuon voi SNS lien account, loi 82.
      ####################################
      length(var.approve_stages) == 0 ? [] : [{
        Sid      = "BaoCoViecCanDuyet"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.approval[0].arn
      }],
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
