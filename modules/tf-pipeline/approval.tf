########################################
# TOPIC BAO CO VIEC CAN DUYET
#
# Chi tao khi co it nhat mot stage trong var.approve_stages. Mot topic
# khong ai bam duyet toi la mot khoan tien nho va mot thu gay hieu nham:
# no lam nguoi doc tuong co cong duyet o dau do.
#
# ---------------------------------------------------------------
# MOI DIA CHI PHAI BAM XAC NHAN
#
# Truoc khi bam, subscription o PendingConfirmation va KHONG nhan gi -
# ma Terraform van bao tao thanh cong. Nen mot cong duyet co topic, co
# subscription, va khong ai duoc bao la mot cau hinh "dung" hoan toan.
#
# Kiem bang phep do, khong bang state:
#
#   aws sns list-subscriptions-by-topic --topic-arn <arn> \
#     --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output text
#   # SubscriptionArn = "PendingConfirmation" -> chua bam
########################################

resource "aws_sns_topic" "approval" {
  count = local.enabled && length(var.approve_stages) > 0 ? 1 : 0

  name = "${local.name}-duyet"
  tags = { Name = "${local.name}-duyet" }
}

resource "aws_sns_topic_subscription" "approval" {
  for_each = local.enabled && length(var.approve_stages) > 0 ? toset(var.approval_emails) : toset([])

  topic_arn = aws_sns_topic.approval[0].arn
  protocol  = "email"
  endpoint  = each.value
}

########################################
# CHO CODEPIPELINE PUBLISH DUOC
#
# Role cua pipeline co sns:Publish trong iam.tf, nhung topic policy cung
# phai cho phep - hai phia, giong SNS lien account (loi 82). Mot phia mo
# mot minh thi khong co loi nao ca: pipeline se bao "khong duyet duoc"
# hoac lang le khong gui thu.
########################################

resource "aws_sns_topic_policy" "approval" {
  count = local.enabled && length(var.approve_stages) > 0 ? 1 : 0

  arn = aws_sns_topic.approval[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ChoPipelineNayPublish"
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.approval[0].arn
      Condition = {
        ArnLike = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:codepipeline:${var.region}:${data.aws_caller_identity.current.account_id}:${local.name}" }
      }
    }]
  })
}

########################################
# KIEM TRA CHEO
########################################

check "co_cong_duyet_thi_co_nguoi_nhan" {
  assert {
    condition = !local.enabled || length(var.approve_stages) == 0 || length(var.approval_emails) > 0
    error_message = join(" ", [
      "approve_stages co", tostring(length(var.approve_stages)), "stage nhung",
      "approval_emails RONG. Cong duyet se dung pipeline lai va KHONG AI duoc",
      "bao - mot lan chay treo o do cho toi khi het gio (7 ngay), va ket qua",
      "doc nhu pipeline bi treo chu khong nhu dang cho nguoi bam.",
    ])
  }
}
