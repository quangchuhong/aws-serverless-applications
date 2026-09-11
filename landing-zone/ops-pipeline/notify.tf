########################################
# TOPIC BAO DRIFT
#
# Tao o ACCOUNT MANAGEMENT - cung account voi pipeline.
#
# VI SAO KHONG DUNG TOPIC CUA config-detective
#
# Topic do nam o account security va resource policy cua no chi cho
# Principal = events.amazonaws.com. Publish lien account can CA HAI
# phia cho phep, va Terraform o day khong sua duoc policy cua mot topic
# o account khac.
#
# Hau qua neu cu tro sang do: buoc drift chay, phat hien dung, roi in
# "CANH BAO: khong bao duoc ve SNS" - moi dem, trong log cua mot job
# khong ai mo. Mot canh bao khong den duoc dich tệ hon khong co canh
# bao, vi no tao cam giac da co nguoi canh.
#
# Van dung duoc topic co san: dat drift_topic_arn. Nhung neu no o
# account khac thi phai tu them statement o phia topic.
########################################

resource "aws_sns_topic" "drift" {
  count = local.enabled && local.tao_topic ? 1 : 0

  name = "${local.name}-drift"
}

resource "aws_sns_topic_subscription" "drift" {
  for_each = local.enabled && local.tao_topic ? toset(var.drift_emails) : []

  topic_arn = aws_sns_topic.drift[0].arn
  protocol  = "email"
  endpoint  = each.value

  # SNS gui thu xac nhan. CHUA BAM LINK = KHONG NHAN DUOC GI.
  #
  # Terraform bao tao thanh cong va `plan` sau do ra "No changes" - o
  # ca hai trang thai. Kiem bang AWS, khong bang state:
  #
  #   aws sns list-subscriptions-by-topic --topic-arn <arn> \
  #     --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table
  #
  # SubscriptionArn con la "PendingConfirmation" = chua bam.
}

check "drift_co_nguoi_nhan" {
  assert {
    condition = !local.enabled || local.drift_topic != ""
    error_message = join(" ", [
      "Ca drift_emails lan drift_topic_arn deu rong, nen buoc phat hien drift",
      "chay ma khong bao ai. No van ghi log CodeBuild - nhung mot phep kiem chi",
      "co gia tri khi co nguoi doc, va khong ai mo log cua mot job chay luc 2",
      "gio sang.",
      "Day la mot lua chon hop le neu ban tu mo log dinh ky - nhung phai la mot",
      "lua chon.",
    ])
  }
}

check "khong_khai_ca_hai_nguon_topic" {
  assert {
    condition = length(var.drift_emails) == 0 || var.drift_topic_arn == ""
    error_message = join(" ", [
      "Khai CA drift_emails VA drift_topic_arn. drift_topic_arn thang, va topic",
      "tu tao se KHONG duoc tao - nen nhung dia chi trong drift_emails khong",
      "nhan duoc gi, va khong co gi bao dieu do.",
      "Chon mot.",
    ])
  }
}
