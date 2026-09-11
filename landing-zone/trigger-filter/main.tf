locals {
  enabled = var.enable
  name    = "${var.project}-trigger-filter"

  # Ten ngan -> ten day du. Ghep o MOT cho: ban do va pipeline lay tien
  # to tu cung mot bien, nen khong co cach nao lech nhau.
  ban_do = {
    for ten, tien_to in var.ban_do :
    "${var.project}-${ten}" => tien_to
  }

  pipeline_arns = [
    for ten in keys(local.ban_do) :
    "arn:${data.aws_partition.current.partition}:codepipeline:${var.region}:${data.aws_caller_identity.current.account_id}:${ten}"
  ]

  ####################################
  # CO AI DUOC BAO KHONG - MOT BIEN BIET DUOC LUC PLAN
  #
  # local.loi_topic o duoi la mot ARN, va khi topic do do chinh layer nay
  # tao thi no CHUA BIET luc plan. Dung no lam count se hong voi:
  #
  #   The "count" value depends on resource attributes that cannot be
  #   determined until apply.
  #
  # Nen cau hoi "co duong bao khong" phai tra loi tu BIEN DAU VAO, va chi
  # cau hoi "bao vao dau" moi duoc cho la chua biet.
  ####################################
  co_bao_loi = var.loi_topic_arn != "" || length(var.loi_emails) > 0

  tao_topic = var.loi_topic_arn == "" && length(var.loi_emails) > 0
  loi_topic = var.loi_topic_arn != "" ? var.loi_topic_arn : try(aws_sns_topic.loi[0].arn, "")
  ####################################
  # ARN KHO: TRA CUU, KHONG TU GHEP
  #
  # Ghep chuoi thi mot ten kho SAI van cho ra mot ARN dung cu phap. Rule
  # EventBridge nhan no, apply xanh, va rule do khong bao gio no - vi
  # khong co su kien nao mang ARN ay. Khong co trieu chung nao.
  #
  # (Da suyt vuong: terraform.tfvars.example cua layer nay tung ghi
  # "aws-serverless-applications" - ten repo GitHub - trong khi kho
  # CodeCommit that ten "diy-aws-landing-zone". Bay layer khac deu ghi
  # dung; chi cho nay lech, va khong co gi bat duoc.)
  #
  # Data source doi kho co THAT: ten sai thi plan CHET ngay voi
  # RepositoryDoesNotExistException, kem dung ten da go.
  ####################################
  repo_arn = local.enabled ? data.aws_codecommit_repository.kho[0].arn : ""

  # Tien to duong dan khong ket thuc bang "/" - xem check ben duoi.
  tien_to_lung_lo = flatten([
    for ten, ds in var.ban_do : [
      for p in ds : "${ten} -> \"${p}\""
      if p != "" && !endswith(p, "/")
    ]
  ])
}

########################################
# KIEM TRA CHEO
########################################

########################################
# BAN DO RONG = CHAN SACH MOI THAY DOI
#
# loc.py cung tu choi ban do rong, nhung do la luc CHAY - tuc sau khi
# rule rieng cua cac pipeline da tat, va sau khi mot commit da vao main.
# Bat o day la bat luc apply.
########################################
check "ban_do_khong_rong" {
  assert {
    condition = !var.enable || length(var.ban_do) > 0
    error_message = join(" ", [
      "var.ban_do RONG nhung layer dang duoc BAT. Mot bo loc khong biet",
      "pipeline nao la mot bo loc chan sach moi thay doi va bao thanh cong.",
      "Khai it nhat mot dong, vi du: ban_do = { vending = [\"landing-zone/account-baseline/\"] }",
    ])
  }
}

########################################
# DANH SACH TIEN TO RONG = PIPELINE KHONG BAO GIO CHAY
#
# Trong tfvars, `vending = []` doc giong "chua dien xong". Luc chay no la
# "khong bao gio khop": str.startswith(()) luon False.
#
# Muon "chay voi moi commit" thi phai viet [""], khong phai [].
########################################
check "khong_co_danh_sach_rong" {
  assert {
    condition = length([for ten, ds in var.ban_do : ten if length(ds) == 0]) == 0
    error_message = join(" ", [
      "Pipeline co danh sach tien to RONG:",
      join(", ", [for ten, ds in var.ban_do : ten if length(ds) == 0]),
      ". Danh sach rong KHONG phai 'chua dien' - no lam pipeline do khong bao",
      "gio duoc khoi dong. Muon no chay voi moi thay doi thi khai [\"\"].",
    ])
  }
}

########################################
# TIEN TO NEN KET THUC BANG "/"
#
# So khop la so khop CHUOI. "landing-zone/network" bat ca
# "landing-zone/network-lz-cu/main.tf" - tuc mot pipeline chay vi mot
# thu muc khac ten gan giong. Chay thua thi khong ai thay, nen no nam
# do lau.
########################################
check "tien_to_ket_thuc_bang_gach_cheo" {
  assert {
    condition = length(local.tien_to_lung_lo) == 0
    error_message = join(" ", [
      "Tien to khong ket thuc bang \"/\":",
      join(", ", local.tien_to_lung_lo),
      ". So khop la so khop CHUOI, nen \"landing-zone/network\" bat ca",
      "\"landing-zone/network-cu/...\". Them dau / vao cuoi, hoac dung \"\"",
      "neu that su muon khop moi duong dan.",
    ])
  }
}

########################################
# BAT THI PHAI CO KHO
########################################
check "co_ten_kho" {
  assert {
    condition = !var.enable || var.repository_name != ""
    error_message = join(" ", [
      "var.enable = true nhung repository_name rong. Rule EventBridge se",
      "khop vao mot ARN CodeCommit khong co ten kho - no khong bao gio no,",
      "va do la kieu hong khong co trieu chung.",
    ])
  }
}

########################################
# CO AI DUOC BAO KHI BO LOC HONG KHONG
########################################
check "co_duong_bao_loi" {
  assert {
    condition = !var.enable || local.co_bao_loi
    error_message = join(" ", [
      "Khong khai loi_topic_arn lan loi_emails. Bo loc nay la diem hong don:",
      "no hong thi khong pipeline nao chay, va dau vet duy nhat la so Errors",
      "cua mot ham Lambda ma khong ai mo ra xem.",
    ])
  }
}

########################################
# HAM LOC
########################################

data "aws_codecommit_repository" "kho" {
  count = local.enabled ? 1 : 0

  repository_name = var.repository_name
}

data "archive_file" "loc" {
  count = local.enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/loc.py"
  output_path = "${path.module}/.build/loc.zip"
}

resource "aws_iam_role" "loc" {
  count = local.enabled ? 1 : 0

  name = local.name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "loc" {
  count = local.enabled ? 1 : 0

  name = "doc-diff-va-khoi-dong"
  role = aws_iam_role.loc[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "Log"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.loc[0].arn}:*"
      },
      {
        Sid      = "DocDiff"
        Effect   = "Allow"
        Action   = ["codecommit:GetDifferences"]
        Resource = local.repo_arn
      },

      ####################################
      # ListPipelines KHONG nhan resource
      #
      # No la mot API cap account - khai ARN o day thi goi bi tu choi.
      # Doi lai, no chi DOC ten, va ten pipeline khong phai bi mat.
      ####################################
      {
        Sid      = "LietKeDeKiemBanDo"
        Effect   = "Allow"
        Action   = ["codepipeline:ListPipelines"]
        Resource = "*"
      },

      ####################################
      # KHOI DONG - CHI NHUNG PIPELINE CO TEN TRONG BAN DO
      #
      # Khong dung "*": mot ban do go sai luc do se khoi dong duoc bat cu
      # pipeline nao trong account. Liet ke ro thi mot ten sai bi IAM tu
      # choi, va loc.py bien cai tu choi do thanh mot lan Lambda bao hong.
      ####################################
      {
        Sid      = "KhoiDong"
        Effect   = "Allow"
        Action   = ["codepipeline:StartPipelineExecution"]
        Resource = local.pipeline_arns
      },
      ],
      !local.co_bao_loi ? [] : [{
        Sid      = "BaoKhiHong"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = local.loi_topic
    }])
  })
}

########################################
# LOG GROUP TAO TRUOC HAM
#
# De Lambda tu tao thi no khong co retention - log giu MAI MAI va tinh
# tien mai mai. Va role o tren tro vao arn cua group nay, nen tao truoc
# cung la cach bo quyen "logs:CreateLogGroup" di.
########################################
resource "aws_cloudwatch_log_group" "loc" {
  count = local.enabled ? 1 : 0

  name              = "/aws/lambda/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "loc" {
  count = local.enabled ? 1 : 0

  function_name = local.name
  role          = aws_iam_role.loc[0].arn
  handler       = "loc.handler"
  runtime       = "python3.12"

  # GetDifferences co phan trang. Mot commit cham hang tram file van xong
  # trong vai giay, nhung het gio o day la mot lan fail-open - tuc moi
  # pipeline chay. Cho rong rai hon la re hon.
  timeout = 60

  filename         = data.archive_file.loc[0].output_path
  source_code_hash = data.archive_file.loc[0].output_base64sha256

  environment {
    variables = {
      BAN_DO      = jsonencode(local.ban_do)
      TIEN_TO_PHU = var.kiem_do_phu ? "${var.project}-" : ""
    }
  }

  depends_on = [aws_cloudwatch_log_group.loc]
}

########################################
# KHI HAM NEM: GOI LAI HAI LAN ROI BAO
#
# EventBridge goi Lambda kieu bat dong bo. Khong khai gi thi mot su kien
# nem het so lan thu se bi VUT DI im lang - tuc mot commit da vao main
# ma khong pipeline nao biet.
#
# on_failure day su kien do vao SNS. Noi dung khong dep (mot ban JSON),
# nhung no tra loi duoc cau hoi "commit nao bi bo sot".
########################################
resource "aws_lambda_function_event_invoke_config" "loc" {
  count = local.enabled && local.co_bao_loi ? 1 : 0

  function_name          = aws_lambda_function.loc[0].function_name
  maximum_retry_attempts = 2

  destination_config {
    on_failure {
      destination = local.loi_topic
    }
  }
}

resource "aws_sns_topic" "loi" {
  count = local.enabled && local.tao_topic ? 1 : 0

  name = "${local.name}-loi"
}

resource "aws_sns_topic_subscription" "loi" {
  for_each = local.enabled && local.tao_topic ? toset(var.loi_emails) : []

  topic_arn = aws_sns_topic.loi[0].arn
  protocol  = "email"
  endpoint  = each.value
}

########################################
# LUAT: MOI COMMIT VAO NHANH, KHONG LOC GI THEM
#
# Day la rule DUY NHAT con lai cho ca he thong pipeline. No co y chay
# rong - moi viec loc nam trong ham, vi tang luat khong co du lieu de
# loc (su kien khong mang danh sach file).
########################################
resource "aws_cloudwatch_event_rule" "commit" {
  count = local.enabled ? 1 : 0

  name        = "${local.name}-commit"
  description = "Moi commit vao ${var.branch_name} -> ham loc quyet dinh pipeline nao chay"

  event_pattern = jsonencode({
    source      = ["aws.codecommit"]
    detail-type = ["CodeCommit Repository State Change"]
    resources   = [local.repo_arn]
    detail = {
      event         = ["referenceCreated", "referenceUpdated"]
      referenceType = ["branch"]
      referenceName = [var.branch_name]
    }
  })
}

resource "aws_cloudwatch_event_target" "loc" {
  count = local.enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.commit[0].name
  target_id = "loc"
  arn       = aws_lambda_function.loc[0].arn
}

resource "aws_lambda_permission" "events" {
  count = local.enabled ? 1 : 0

  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.loc[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.commit[0].arn
}
