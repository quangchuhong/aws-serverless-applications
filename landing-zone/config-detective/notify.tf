########################################
# CANH BAO
#
# QUYET DINH KIEN TRUC - doc truoc khi sua file nay:
#
# KHONG lam EventBridge fan-in cross-account.
#
# Config managed rule TU DAY finding vao Security Hub, va Security Hub
# da co san gom cross-account + cross-region qua delegated admin.
# Dung mot duong EventBridge rieng cho "Config non-compliant" la lam
# lai dung viec do, va phai trien khai rule + IAM role o MOI account
# x MOI region - qua StackSet, them mot thu phai bao tri.
#
# Nen o day chi co MOT rule EventBridge, dat NGAY TAI security account,
# doc finding Security Hub da gom san.
#
# Loi them: cung mot duong nay gom luon GuardDuty, Inspector, Macie -
# khong phai lam rieng tung service.
#
#   Config rule vi pham
#      └─► Security Hub (delegated admin, tu gom moi account/region)
#            └─► EventBridge rule TAI security account
#                  ├─► SNS ─► email
#                  └─► Lambda ─► Slack   (tuy chon)
########################################

resource "aws_sns_topic" "alerts" {
  count    = local.enabled ? 1 : 0
  provider = aws.security

  name = "${var.project}-security-findings"
}

resource "aws_sns_topic_policy" "alerts" {
  count    = local.enabled ? 1 : 0
  provider = aws.security

  arn = aws_sns_topic.alerts[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts[0].arn
    }]
  })
}

resource "aws_sns_topic_subscription" "email" {
  for_each = local.enabled ? toset(var.alert_emails) : []
  provider = aws.security

  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = each.value

  # SNS gui thu xac nhan. CHUA BAM LINK = KHONG NHAN DUOC CANH BAO NAO.
  # Day la buoc hay quen nhat trong ca layer.
  #
  # ---------------------------------------------------------------
  # VA TERRAFORM KHONG BAO CHO BAN BIET KHI NO HONG.
  #
  # Do duoc trong lan dung that - chi ghi cai QUAN SAT DUOC:
  #
  #   terraform state   ->  ARN that, ket thuc bang UUID
  #   terraform plan    ->  No changes         (Terraform noi ON)
  #   SNS               ->  Deleted            (khong ai nhan gi)
  #
  # Provider truyen ReturnSubscriptionArn=true nen SNS tra ARN that
  # NGAY CA khi subscription chua duoc xac nhan. State giu ARN do, va
  # khi SNS xoa subscription chua xac nhan (sau 3 NGAY), plan van sach.
  #
  # Day KHONG phai drift ma plan phat hien duoc - la drift ma plan
  # KHANG DINH la khong co. Khong co lifecycle hay check block nao
  # sua duoc: Terraform khong co data source doc subscription cua SNS.
  #
  # Nen cach duy nhat la hoi thang SNS - xem muc 1 trong output
  # next_steps.
  #
  # LUU Y ve -replace: SNS Subscribe voi cung topic + protocol +
  # endpoint co the tra ve DUNG ARN cu thay vi tao cai moi. Terraform
  # se bao "1 added, 1 destroyed" ma ben SNS khong doi gi. Doc log cua
  # Terraform khong du - phai list-subscriptions-by-topic lai.
  # ---------------------------------------------------------------
}

########################################
# EventBridge rule
########################################

resource "aws_cloudwatch_event_rule" "findings" {
  count    = local.enabled ? 1 : 0
  provider = aws.security

  name        = "${var.project}-security-findings"
  description = "Finding FAILED muc ${join("/", var.alert_severities)} tu Security Hub"

  event_pattern = jsonencode({
    source        = ["aws.securityhub"]
    "detail-type" = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        # Chi bao cai DANG sai va CHUA duoc xu ly.
        # Thieu hai dieu kien duoi thi moi lan finding duoc cap nhat
        # trang thai cung ban thong bao - rat nhanh thanh nhieu.
        Compliance  = { Status = ["FAILED"] }
        RecordState = ["ACTIVE"]
        Workflow    = { Status = ["NEW", "NOTIFIED"] }

        Severity = { Label = var.alert_severities }
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "sns" {
  count    = local.enabled ? 1 : 0
  provider = aws.security

  rule      = aws_cloudwatch_event_rule.findings[0].name
  target_id = "sns"
  arn       = aws_sns_topic.alerts[0].arn

  # Email tho tu Security Hub rat kho doc - rut gon con nhung truong
  # thuc su can
  input_transformer {
    input_paths = {
      account  = "$.detail.findings[0].AwsAccountId"
      region   = "$.detail.findings[0].Region"
      severity = "$.detail.findings[0].Severity.Label"
      title    = "$.detail.findings[0].Title"
      resource = "$.detail.findings[0].Resources[0].Id"
    }

    input_template = <<-EOT
      "[<severity>] <title>"
      "Account : <account>"
      "Region  : <region>"
      "Resource: <resource>"
    EOT
  }
}

########################################
# Lambda -> Slack (tuy chon)
#
# Webhook URL nam trong Secrets Manager, KHONG nam trong bien
# Terraform - bien se vao state o dang ro.
########################################

data "archive_file" "slack" {
  count = local.enabled && var.enable_slack ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/slack_notify.py"
  output_path = "${path.module}/.build/slack_notify.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  count = local.enabled && var.enable_slack ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "slack" {
  count    = local.enabled && var.enable_slack ? 1 : 0
  provider = aws.security

  name               = "${var.project}-slack-notify"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume[0].json
}

resource "aws_iam_role_policy" "slack" {
  count    = local.enabled && var.enable_slack ? 1 : 0
  provider = aws.security

  name = "read-webhook-and-log"
  role = aws_iam_role.slack[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:${data.aws_partition.current.partition}:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = "arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${var.security_account_id}:secret:${var.slack_webhook_secret_name}-*"
      },
    ]
  })
}

resource "aws_lambda_function" "slack" {
  count    = local.enabled && var.enable_slack ? 1 : 0
  provider = aws.security

  function_name = "${var.project}-slack-notify"
  role          = aws_iam_role.slack[0].arn
  handler       = "slack_notify.handler"
  runtime       = "python3.12"
  timeout       = 15

  filename         = data.archive_file.slack[0].output_path
  source_code_hash = data.archive_file.slack[0].output_base64sha256

  environment {
    variables = {
      SECRET_NAME = var.slack_webhook_secret_name
    }
  }
}

resource "aws_lambda_permission" "events" {
  count    = local.enabled && var.enable_slack ? 1 : 0
  provider = aws.security

  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.findings[0].arn
}

resource "aws_cloudwatch_event_target" "slack" {
  count    = local.enabled && var.enable_slack ? 1 : 0
  provider = aws.security

  rule      = aws_cloudwatch_event_rule.findings[0].name
  target_id = "slack"
  arn       = aws_lambda_function.slack[0].arn
}

########################################
# KIEM TRA CHEO
########################################

check "alert_channel_exists" {
  assert {
    condition     = !local.enabled || length(var.alert_emails) > 0 || var.enable_slack
    error_message = "Bat layer nhung khong co kenh canh bao nao - finding se do vao Security Hub ma khong ai biet. Dien alert_emails hoac bat enable_slack."
  }
}
