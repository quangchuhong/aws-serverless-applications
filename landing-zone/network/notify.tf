########################################
# TOPIC BAO DONG CUA MANG
#
# Tao o CHINH account mang - cung account voi cac alarm dung no.
#
# =======================================================================
# VI SAO KHONG TRO SANG TOPIC CUA config-detective
#
# Topic quh11-lz-security-findings nam o account SECURITY. CloudWatch
# alarm ban sang SNS LIEN ACCOUNT can resource policy cua topic cho phep
# service principal cloudwatch.amazonaws.com tu account nay - va policy
# do khong co. Terraform o day cung khong sua duoc policy cua mot topic o
# account khac.
#
# Hau qua neu cu tro sang do: alarm doi trang thai, SNS tu choi publish,
# va khong co gi bao rang canh bao khong den duoc. Mot canh bao khong toi
# dich TE HON khong co canh bao, vi no tao cam giac da co nguoi canh.
#
# Cung ket luan ma modules/tf-pipeline/notify.tf da ghi cho drift, va cung
# la ly do file nay ton tai thay vi mot dong ARN tro sang account khac.
#
# =======================================================================
# VI SAO O LAYER NAY CHU KHONG O ops/
#
# ops/ la lop thay doi HANG NGAY - them mot rule, mo mot port. Topic bao
# dong thi doi vai lan mot nam. Va pipeline ops chi -target vao mot danh
# sach resource co san; mot topic khai o ops/ se khong bao gio duoc
# pipeline apply, tuc no se la mot thu chi dung bang tay nam lan giua
# nhung thu chay tu dong.
#
# Dat o day thi no di theo dung nhip cua no, va ops/ nhan ARN qua
# ops_handles - khong ai phai go lai mot ARN da ton tai o cho khac. Do
# la nguyen tac da ghi san trong ops_handles (loi 111: hai noi go tay
# cung mot gia tri thi mot ngay nao do chung se lech).
########################################

resource "aws_sns_topic" "netops" {
  count = var.enable_netops_alerts ? 1 : 0

  name = "${var.project}-netops"
}

########################################
# SNS GUI THU XAC NHAN - CHUA BAM LINK = KHONG NHAN DUOC GI
#
# Terraform bao tao thanh cong va `plan` sau do ra "No changes" o CA HAI
# trang thai: da bam va chua bam. Nen state khong tra loi duoc cau hoi
# nay, phai hoi AWS:
#
#   aws sns list-subscriptions-by-topic --topic-arn <arn> \
#     --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table
#
# SubscriptionArn con la "PendingConfirmation" = chua bam.
########################################
resource "aws_sns_topic_subscription" "netops" {
  for_each = var.enable_netops_alerts ? toset(var.netops_emails) : []

  topic_arn = aws_sns_topic.netops[0].arn
  protocol  = "email"
  endpoint  = each.value
}

########################################
# CO TOPIC MA KHONG CO AI NHAN - IM LANG NHAT TRONG CA FILE
#
# Topic ton tai, alarm ban vao no thanh cong, va khong mot ai duoc bao.
# Moi lop deu xanh: alarm co action, SNS nhan message, Terraform khong
# co gi de noi.
#
# check chu khong validation: de rong la mot lua chon HOP LE khi dang
# dung thu. Nhung no phai la mot lua chon, khong phai mot cho bi quen.
########################################
check "netops_topic_co_nguoi_nhan" {
  assert {
    condition     = !var.enable_netops_alerts || length(var.netops_emails) > 0
    error_message = join(" ", [
      "enable_netops_alerts dang BAT nhung netops_emails RONG.",
      "Topic se duoc tao, alarm se ban vao no thanh cong, va khong ai duoc bao.",
      "Moi lop deu xanh - do la kieu hong khong co trieu chung nao.",
      "Dien dia chi, hoac tat enable_netops_alerts de viec khong bao ai la mot",
      "lua chon duoc ghi lai.",
    ])
  }
}

variable "enable_netops_alerts" {
  description = <<-EOT
    Tao topic SNS nhan canh bao van hanh mang o CHINH account nay.

    Cac alarm cua lop ops/ (duong ham VPN doi tac) lay ARN nay qua
    ops_handles, nen khong ai phai go lai ARN o ops/terraform.tfvars.

    TAT thi ops/ khong co dich bao dong nao tru khi alarm_actions ben do
    duoc dien tay - va luc do hai alarm van duoc tao, van doi mau trong
    console, va khong goi ai.
  EOT
  type        = bool
  default     = true
}

variable "netops_emails" {
  description = <<-EOT
    Dia chi nhan canh bao van hanh mang.

    MOI dia chi nhan mot thu xac nhan tu SNS va PHAI BAM LINK. Truoc do
    subscription o trang thai PendingConfirmation va khong nhan gi -
    trong khi Terraform van bao tao thanh cong va plan van ra No changes.

    Kiem bang AWS chu khong bang state:
      aws sns list-subscriptions-by-topic --topic-arn <arn> \
        --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table
  EOT
  type        = list(string)
  default     = []

  # [""] khong phai []: length la 1, va apply se do o giua khi SNS tu
  # choi endpoint rong. Bat tu plan.
  validation {
    condition     = alltrue([for e in var.netops_emails : can(regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", e))])
    error_message = "netops_emails co phan tu khong phai dia chi email. De trong thi viet [] - [\"\"] la danh sach CO MOT phan tu rong."
  }
}
