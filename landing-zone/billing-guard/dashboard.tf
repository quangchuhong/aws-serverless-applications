########################################
# CloudWatch dashboard cho chi phi (TUY CHON)
#
# DOC README MUC "Dashboard tap trung" TRUOC KHI BAT.
#
# Cost Explorer o management account da la dashboard tap trung
# cho moi account, mien phi, khong phai build gi. Dashboard nay
# chi de gan chi phi canh cac dashboard van hanh khac.
#
# Han che cua metric AWS/Billing:
#   - Do phan giai 6 tieng
#   - Chi co tong va theo service, KHONG chia duoc theo account/tag
#   - Can bat "Receive Billing Alerts" thu cong truoc
########################################

resource "aws_cloudwatch_dashboard" "billing" {
  count = var.enable_cloudwatch_dashboard ? 1 : 0

  dashboard_name = "${var.project}-billing"

  dashboard_body = jsonencode({
    widgets = concat(
      [
        {
          type   = "text"
          x      = 0
          y      = 0
          width  = 24
          height = 2
          properties = {
            markdown = join("\n", [
              "# Chi phi ${var.project}",
              "Metric AWS/Billing cap nhat moi ~6 tieng va khong chia duoc theo account hay tag.",
              "Phan tich chi tiet dung **Cost Explorer** o management account (mien phi).",
            ])
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 2
          width  = 12
          height = 6
          properties = {
            title  = "Tong chi phi uoc tinh (USD)"
            region = "us-east-1"
            view   = "timeSeries"
            stat   = "Maximum"
            period = 21600 # 6 tieng - do phan giai that cua metric
            metrics = [
              ["AWS/Billing", "EstimatedCharges", "Currency", "USD"]
            ]
            annotations = {
              horizontal = [
                {
                  label = "Nguong canh bao"
                  value = tonumber(var.org_monthly_budget_usd)
                }
              ]
            }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 2
          width  = 12
          height = 6
          properties = {
            title   = "Theo service"
            region  = "us-east-1"
            view    = "timeSeries"
            stacked = true
            stat    = "Maximum"
            period  = 21600
            metrics = [
              for s in var.dashboard_services :
              ["AWS/Billing", "EstimatedCharges", "ServiceName", s, "Currency", "USD"]
            ]
          }
        },
      ],

      # Canh bao neu con resource demo dang chay
      [
        {
          type   = "text"
          x      = 0
          y      = 8
          width  = 24
          height = 3
          properties = {
            markdown = join("\n", [
              "## Kiem tra con resource demo dang chay khong",
              "```",
              "aws resourcegroupstaggingapi get-resources --region ap-southeast-1 \\",
              "  --tag-filters 'Key=Ephemeral,Values=true' \\",
              "  --query 'length(ResourceTagMappingList)' --output text",
              "```",
              "Khac 0 nghia la demo chua duoc xoa.",
            ])
          }
        }
      ]
    )
  })
}

########################################
# Alarm tren metric billing
#
# Trung lap mot phan voi budget, nhung co diem khac:
# alarm nay ban vao SNS ngay khi vuot nguong, con budget
# co the tre vai tieng.
########################################

resource "aws_cloudwatch_metric_alarm" "estimated_charges" {
  count = var.enable_cloudwatch_dashboard ? 1 : 0

  alarm_name          = "${var.project}-estimated-charges"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600
  statistic           = "Maximum"
  threshold           = tonumber(var.org_monthly_budget_usd)

  dimensions = {
    Currency = "USD"
  }

  alarm_description = "Chi phi uoc tinh vuot ${var.org_monthly_budget_usd} USD"
  alarm_actions     = [aws_sns_topic.billing_alerts.arn]
  ok_actions        = [aws_sns_topic.billing_alerts.arn]

  # Chua co du lieu khong co nghia la on
  treat_missing_data = "notBreaching"
}
