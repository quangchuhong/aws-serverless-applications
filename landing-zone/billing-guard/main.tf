########################################
# 1. COST ALLOCATION TAG
#
# Khong hoi to. Day la ly do duy nhat phai lam SOM.
# Mat ~24h moi thay trong Cost Explorer.
# Chi bat duoc o management account.
########################################

resource "aws_ce_cost_allocation_tag" "tracked" {
  for_each = var.enable_cost_allocation_tags ? toset(var.cost_allocation_tags) : []

  tag_key = each.value
  status  = "Active"
}

########################################
# 2. SNS - kenh canh bao chung
#
# Dung SNS thay vi email truc tiep trong budget de sau nay
# them Slack/Lambda ma khong phai sua tung budget.
########################################

resource "aws_sns_topic" "billing_alerts" {
  name = "${var.project}-billing-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.billing_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# Budgets va Cost Anomaly Detection can quyen publish vao topic nay
resource "aws_sns_topic_policy" "billing_alerts" {
  arn = aws_sns_topic.billing_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowBudgets"
        Effect    = "Allow"
        Principal = { Service = "budgets.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.billing_alerts.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        Sid       = "AllowCostAnomalyDetection"
        Effect    = "Allow"
        Principal = { Service = "costalerts.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.billing_alerts.arn
      }
    ]
  })
}

########################################
# 3. BUDGET TOAN ORGANIZATION
#
# Lop bao ve chinh cho mo hinh dung-xoa: neu quen xoa demo,
# canh bao toi truoc khi hoa don len den vai tram do.
########################################

resource "aws_budgets_budget" "org_guard" {
  name         = "${var.project}-org-guard"
  budget_type  = "COST"
  limit_amount = var.org_monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Bo qua credit va refund de con so phan anh dung muc tieu thu that
  cost_types {
    include_credit = false
    include_refund = false
    include_tax    = true
    use_blended    = false
  }

  # Canh bao theo chi phi THUC TE da phat sinh
  dynamic "notification" {
    for_each = toset(var.budget_thresholds)

    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [aws_sns_topic.billing_alerts.arn]
    }
  }

  # Canh bao theo DU BAO - bat som hon, truoc khi tien that phat sinh
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.billing_alerts.arn]
  }

  depends_on = [aws_sns_topic_policy.billing_alerts]
}

########################################
# 4. BUDGET THEO TUNG ACCOUNT (tuy chon)
########################################

resource "aws_budgets_budget" "per_account" {
  for_each = var.account_budgets

  name         = "${var.project}-${each.key}"
  budget_type  = "COST"
  limit_amount = each.value.limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "LinkedAccount"
    values = [each.value.account_id]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.billing_alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.billing_alerts.arn]
  }

  depends_on = [aws_sns_topic_policy.billing_alerts]
}

########################################
# 5. COST ANOMALY DETECTION
#
# Khac budget: budget bat "vuot han muc", anomaly bat
# "hom nay tu nhien ton gap ba lan binh thuong" - ke ca khi
# tong van duoi han muc.
#
# Mien phi.
########################################

# GIOI HAN CUA AWS: moi account chi duoc MOT dimensional monitor, va
# AWS thuong da tu tao san mot cai ten "Services" khi Cost Explorer
# duoc bat. Gap "Limit exceeded on dimensional spend monitor creation"
# thi khong phai loi cau hinh - dien ARN cai dang co vao
# var.service_anomaly_monitor_arn de dung lai no.
resource "aws_ce_anomaly_monitor" "by_service" {
  count = var.service_anomaly_monitor_arn == "" ? 1 : 0

  name              = "${var.project}-by-service"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

locals {
  # Dung cai co san neu duoc khai, khong thi dung cai vua tao
  service_anomaly_monitor_arn = (
    var.service_anomaly_monitor_arn != ""
    ? var.service_anomaly_monitor_arn
    : aws_ce_anomaly_monitor.by_service[0].arn
  )
}

########################################
# RANG BUOC CUA AWS - hai truong nay KHONG doc lap nhau:
#
#   DAILY / WEEKLY  ->  CHI nhan subscriber kieu EMAIL
#   IMMEDIATE       ->  nhan SNS (va EMAIL)
#
# Ghep sai:
#   ValidationException: Daily or weekly frequencies only support
#   Email subscriptions
#
# var.anomaly_alert_mode dat ca hai truong cung luc de khong ghep sai
# duoc. Xem mo ta bien de chon.
########################################

resource "aws_ce_anomaly_subscription" "alerts" {
  name      = "${var.project}-anomaly-alerts"
  frequency = var.anomaly_alert_mode == "email_daily" ? "DAILY" : "IMMEDIATE"

  monitor_arn_list = [local.service_anomaly_monitor_arn]

  # Qua SNS: mot subscriber duy nhat, fan-out o tang topic
  dynamic "subscriber" {
    for_each = var.anomaly_alert_mode == "sns_immediate" ? [aws_sns_topic.billing_alerts.arn] : []
    content {
      type    = "SNS"
      address = subscriber.value
    }
  }

  # Qua email: Cost Explorer gui THANG, khong di qua topic - nen
  # phai liet ke tung dia chi o day.
  dynamic "subscriber" {
    for_each = var.anomaly_alert_mode == "email_daily" ? toset(var.alert_emails) : toset([])
    content {
      type    = "EMAIL"
      address = subscriber.value
    }
  }

  # Chi bao khi anh huong vuot nguong - tranh nhieu tu dao dong nho
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = [var.anomaly_threshold_usd]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }

  depends_on = [aws_sns_topic_policy.billing_alerts]
}
