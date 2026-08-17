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
