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
# TRU RA: LAYER LONG NHAU TRONG CAY THU MUC
#
# Khoa giong ban_do (ten NGAN). Gia tri la tien to bi loai khoi pipeline
# do, KE CA khi mot tien to trong ban_do cua no co bat.
#
# Vi sao can, khi ban_do da noi ro cai gi thuoc ai: vi layer long nhau.
#
#   landing-zone/network/       vending apply (stage B, D)
#   landing-zone/network/ops/   layer RIENG, pipeline rieng, state rieng
#
# So khop la so khop CHUOI, nen tien to "landing-zone/network/" bat ca
# moi file trong "network/ops/". Khong co cach nao viet mot tien to nghia
# la "network/ nhung khong network/ops/".
#
# Khong khai thi moi lan sua lop van hanh mang - thu doi HANG NGAY - se
# keo vending chay vo ich, kem mot cong duyet treo mang nhan "tao
# account". Do khong phai loi, chi la on - va on lau thi nguoi ta thoi
# doc.
#
# HAI CACH KHAI SAI, ca hai duoc loc.py bat moi lan chay (phep 4 va 5):
#   - goi ten mot pipeline khong co trong ban_do -> ngoai le da het han
#   - tru chan sach mot tien to gom -> pipeline coi nhu mat tien to do,
#     va phai doc CA HAI dong moi thay
########################################
variable "tru" {
  type        = map(list(string))
  description = "Ten ngan cua pipeline -> tien to bi loai tru, ke ca khi ban_do co bat."
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

########################################
# LAYER CO CHU DICH KHONG CO DUONG TU DONG
#
# Khong phai layer nao cung co pipeline. Mot layer duoc mot pipeline
# APPLY nhung khong duong dan nao trong ban_do cham toi thi thay doi cua
# no vao main roi nam do - khong gi chay, khong gi bao.
#
# Rong la hop le, nhung phai duoc VIET RA kem ly do. Mot dong trong doc
# giong het mot dong bi quen, va cai thu hai la mot layer khong ai apply.
#
# Cung loi voi khong_co_lint va khong_co_catalog: kiem-module.py doi chieu
# danh sach nay voi MOI `layer = "..."` khai trong cac caller pipeline, va
# keu khi co layer nao khong nam o ca hai ben.
########################################
variable "layer_thu_cong" {
  type        = list(string)
  description = "Layer duoc pipeline apply nhung CO CHU DICH khong co duong kich hoat tu dong."
  default     = []
}

variable "log_retention_days" {
  type    = number
  default = 90
}
