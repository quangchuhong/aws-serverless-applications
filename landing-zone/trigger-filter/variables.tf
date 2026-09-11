variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project" {
  type    = string
  default = "acme-lz"
}

variable "cost_center" {
  type    = string
  default = "CC-0000"
}

variable "owner" {
  type    = string
  default = "platform@example.com"
}

########################################
# MAC DINH TAT
#
# Bat cai nay KHONG nguy hiem theo chieu quyen - ham chi doc diff va goi
# StartPipelineExecution. Cai phai can nhac la THU TU: xem khoi dau
# versions.tf. Bat layer nay truoc, tat rule rieng sau.
########################################
variable "enable" {
  type    = bool
  default = false
}

variable "repository_name" {
  type        = string
  description = "Kho CodeCommit chua code landing zone."
  default     = ""
}

variable "branch_name" {
  type    = string
  default = "main"
}

########################################
# BAN DO: PIPELINE -> DUONG DAN NO QUAN TAM
#
# Khoa la ten NGAN cua pipeline. Ten day du do Terraform ghep:
# "${var.project}-${khoa}". Viet ngan o day de mot lan go sai tien to
# project khong the xay ra - ban do va pipeline lay tien to tu CUNG mot
# bien.
#
# Gia tri la danh sach TIEN TO CHUOI, khong phai glob. Nen:
#
#   "landing-zone/network/"    dung  - co dau / nen khong bat
#                                      "landing-zone/network-cu/"
#   "landing-zone/network"     bat CA "landing-zone/network-cu/..."
#   ""                         chay voi MOI thay doi (hop le, co chu dich)
#   []                         pipeline KHONG BAO GIO chay - la loi
#
# Dong cuoi dang chu y: mot danh sach rong doc giong "chua dien" va chay
# giong "da tat". loc.py coi do la loi cung, va check
# "khong_co_danh_sach_rong" ben duoi bat no som hon mot vong.
########################################
variable "ban_do" {
  type        = map(list(string))
  description = "Ten ngan cua pipeline -> tien to duong dan no quan tam."
  default     = {}
}

########################################
# DO PHU: CHIEU HONG NGUY HIEM NHAT
#
# Sau khi rule rieng cua tung pipeline bi tat, ban_do la duong DUY NHAT
# den chung. Mot pipeline bi quen o day van ton tai, van xanh trong
# console, va khong bao gio chay nua.
#
# Bat cai nay thi loc.py liet ke pipeline that o AWS moi lan chay, va bao
# HONG neu co cai nao mang tien to "${project}-" ma khong co trong ban do.
#
# Tat no di neu trong account co pipeline mang cung tien to nhung CO CHU
# DICH chi chay bang tay.
########################################
variable "kiem_do_phu" {
  type    = bool
  default = true
}

########################################
# BAO KHI BO LOC HONG
#
# Bo loc nay la mot diem hong don: no hong thi khong pipeline nao chay.
# loc.py da chon fail-open cho moi thu no du doan duoc, nhung mot ham bi
# throttle, het bo nho, hay nem o cho khong ngo thi EventBridge goi lai
# hai lan roi VUT su kien di - khong con dau vet nao ngoai so Errors.
#
# Khai mot trong hai (hoac ca hai) de so do thanh mot email.
########################################
variable "loi_topic_arn" {
  type        = string
  description = "SNS topic co san. Uu tien hon loi_emails neu khai ca hai."
  default     = ""
}

variable "loi_emails" {
  type        = list(string)
  description = "Dia chi nhan bao khi bo loc hong. Moi dia chi phai bam xac nhan."
  default     = []
}

variable "log_retention_days" {
  type    = number
  default = 90
}
