variable "project" {
  type    = string
  default = "acme-lz"
}

variable "cost_center" {
  description = "Tag CostCenter cho chinh ha tang quan tri nay"
  type        = string
  default     = "CC-0000"
}

variable "owner" {
  description = "Tag Owner - email doi platform"
  type        = string
  default     = "platform@example.com"
}

variable "alert_emails" {
  description = "Email nhan canh bao. Moi email phai XAC NHAN qua link SNS gui toi."
  type        = list(string)
}

########################################
# 1. Cost allocation tag
#
# DAY LA PHAN QUAN TRONG NHAT VE THOI DIEM:
# tag khong hoi to. Bat hom nay -> du lieu phan bo bat dau tu hom nay.
# Bat muon = mat vinh vien du lieu cua giai doan truoc do.
########################################

variable "cost_allocation_tags" {
  description = <<-EOT
    Tag key can theo doi trong Cost Explorer.

    LUU Y: tag chi bat duoc SAU KHI da co it nhat mot resource mang tag do.
    Chua co resource nao -> apply se loi. Khi do dat enable_cost_allocation_tags
    = false, dung LZ truoc, roi quay lai bat.
  EOT
  type        = list(string)

  default = [
    "CostCenter",
    "Environment",
    "Project",
    "Owner",
  ]
}

variable "enable_cost_allocation_tags" {
  description = "Tat khi chua co resource nao mang cac tag tren"
  type        = bool
  default     = true
}

########################################
# 2. Budget
########################################

variable "org_monthly_budget_usd" {
  description = <<-EOT
    Nguong canh bao cho TOAN BO organization.

    Voi mo hinh dung-xoa (demo ~$3/buoi), dat thap - vi du 20.
    Cham nguong = co gi do dang chay ma ban khong biet.
  EOT
  type        = string
  default     = "20"
}

variable "budget_thresholds" {
  description = "Cac moc % de canh bao"
  type        = list(number)
  default     = [50, 80, 100]
}

variable "account_budgets" {
  description = <<-EOT
    Budget rieng cho tung account. De trong cung duoc.
    Key = ten de doc, value = { account_id, limit_usd }
  EOT
  type = map(object({
    account_id = string
    limit_usd  = string
  }))
  default = {}
}

########################################
# 3. Cost Anomaly Detection
########################################

variable "anomaly_threshold_usd" {
  description = "Chi canh bao khi bat thuong vuot so tien nay (tranh nhieu)"
  type        = string
  default     = "10"
}

variable "anomaly_alert_mode" {
  description = <<-EOT
    Cach gui canh bao bat thuong chi phi. Hai tuy chon:

      sns_immediate  Bao NGAY khi phat hien, qua SNS topic cua layer nay.
                     Topic la diem phan phoi - sau nay them Slack, Lambda,
                     PagerDuty ma khong phai dung toi Cost Explorer.

      email_daily    Ban tong hop MOI NGAY, Cost Explorer gui THANG toi
                     tung dia chi trong var.alert_emails. KHONG di qua
                     SNS topic.

    ---------------------------------------------------------------
    VI SAO PHAI LA MOT BIEN, KHONG PHAI HAI:

    frequency va subscriber.type cua aws_ce_anomaly_subscription
    khong doc lap nhau:

      DAILY / WEEKLY  ->  CHI nhan subscriber kieu EMAIL
      IMMEDIATE       ->  nhan SNS

    Ghep sai thi apply moi bao:
      ValidationException: Daily or weekly frequencies only support
      Email subscriptions

    Mot bien dat ca hai truong cung luc thi khong ghep sai duoc.
    ---------------------------------------------------------------

    Khuyen nghi sns_immediate: voi canh bao chi phi, biet muon mot ngay
    la da ton them mot ngay. Nguong var.anomaly_threshold_usd da loc
    nhieu roi nen khong so bi lam phien.
  EOT
  type        = string
  default     = "sns_immediate"

  validation {
    condition     = contains(["sns_immediate", "email_daily"], var.anomaly_alert_mode)
    error_message = "Chi chap nhan: sns_immediate hoac email_daily."
  }

  validation {
    condition     = var.anomaly_alert_mode != "email_daily" || length(var.alert_emails) > 0
    error_message = "email_daily can it nhat mot dia chi trong alert_emails - khong thi subscription sinh ra khong co nguoi nhan nao va khong ai biet."
  }
}

variable "service_anomaly_monitor_arn" {
  description = <<-EOT
    ARN cua DIMENSIONAL anomaly monitor da co san. De RONG de Terraform
    tao moi.

    ---------------------------------------------------------------
    GIOI HAN CUA AWS: MOI ACCOUNT CHI DUOC MOT dimensional monitor.

    Va AWS thuong da TU TAO san mot cai ten "Services" khi Cost
    Explorer duoc bat lan dau. Nen apply lan dau rat de gap:

      ValidationException: Limit exceeded on dimensional spend
      monitor creation

    Do KHONG phai loi cau hinh - la da co mot cai roi.
    ---------------------------------------------------------------

    Tim cai dang co:

      aws ce get-anomaly-monitors \
        --query 'AnomalyMonitors[?MonitorType==`DIMENSIONAL`].[MonitorName,MonitorArn]' \
        --output table

    Ra ket qua -> dien ARN vao day. Terraform bo qua buoc tao va gan
    thang subscription vao monitor do.

    Rong -> de bien nay rong, Terraform tao moi.

    KHONG dung terraform import cho truong hop nay tru khi ban muon
    Terraform lam chu cai monitor cua AWS - go layer nay ve sau se xoa
    luon no.

    LUU Y GIONG create_organization: bien nay dieu khien count. Dien ARN
    vao SAU KHI Terraform da tu tao monitor nghia la count 1 -> 0, tuc
    ke hoach XOA cai monitor Terraform dang quan ly. Chon mot lan o lan
    apply dau, roi giu nguyen.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.service_anomaly_monitor_arn == "" || can(regex("^arn:aws[a-z-]*:ce::[0-9]{12}:anomalymonitor/", var.service_anomaly_monitor_arn))
    error_message = "Phai la ARN anomaly monitor (arn:aws:ce::<account>:anomalymonitor/...) hoac de rong."
  }
}

########################################
# 4. Dashboard (tuy chon)
########################################

variable "enable_cloudwatch_dashboard" {
  description = <<-EOT
    Dashboard CloudWatch dung metric AWS/Billing.

    CAN BUOC THU CONG TRUOC: bat "Receive Billing Alerts" trong
    Billing console -> Billing preferences. Khong bat thi metric
    khong ton tai va dashboard trong tron.

    Han che: do phan giai 6 tieng, chi co tong va theo service.
    Cost Explorer manh hon nhieu - xem README muc "Dashboard tap trung".
  EOT
  type        = bool
  default     = false
}

variable "dashboard_services" {
  description = "Service hien tren dashboard CloudWatch"
  type        = list(string)
  default = [
    "AmazonEC2",
    "AmazonVPC",
    "AWSNetworkFirewall",
    "AmazonS3",
    "AWSTransitGateway",
  ]
}
