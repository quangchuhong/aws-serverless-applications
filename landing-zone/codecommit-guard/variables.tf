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
# Bat cai nay lam mot viec khong hoan tac duoc bang Terraform: nguoi dang
# lam viec hang ngay se khong push thang vao main duoc nua. Neu pool duyet
# khai sai thi khong ai merge duoc gi, ke ca chinh ban va - va duong sua
# la vao IAM console thao policy ra bang tay.
#
# Doc output `phai_lam_gi` TRUOC khi bat.
########################################

variable "enable" {
  type    = bool
  default = false
}

variable "repository_name" {
  description = <<-EOT
    Ten repo CodeCommit. PHAI khop voi repository_name cua ca hai
    pipeline, neu khong thi template gan vao mot repo khong ai dung.

    Repo KHONG do Terraform quan - no duoc tao tay. Layer nay khong
    import no, chi gan template vao. Lay ten that:

      aws codecommit list-repositories --region <region>
  EOT
  type        = string
  default     = "diy-aws-landing-zone"
}

variable "branch_name" {
  description = <<-EOT
    Nhanh duoc bao ve. PHAI la nhanh ma pipeline dang nghe.

    Bao ve sai nhanh la truong hop te nhat: Terraform apply thanh cong,
    approval rule co that, va duong chay thuc su van khong bi chan.

      cd ../ops-pipeline && terraform output -json layers
      grep branch_name terraform.tfvars
  EOT
  type        = string
  default     = "main"
}

########################################
# AI DUOC DUYET
########################################

variable "pool_duyet" {
  description = <<-EOT
    Danh sach "approval pool member" cua CodeCommit. KHONG co mac dinh,
    va co chu dich: mot ARN doan ra la mot chot duyet trong nhu dang chay
    ma khong ai trong pool thoa man duoc.

    HAI DANG CodeCommit nhan:

      arn:aws:sts::<account>:assumed-role/<ten-role>/*
      arn:aws:iam::<account>:user/<ten-user>

    Voi IAM Identity Center (SSO) thi la dang thu nhat, va ten role co
    hinh AWSReservedSSO_<ten-permission-set>_<hau-to-bam>.

    DO CHU KHONG DOAN - nho mot nguoi trong doi bao mat dang nhap roi
    chay:

      aws sts get-caller-identity --query Arn --output text

    Ket qua co dang:
      arn:aws:sts::609320954321:assumed-role/AWSReservedSSO_lz-sec_abc123/ten.nguoi

    Doi phan cuoi thanh * de trum ca doi:
      arn:aws:sts::609320954321:assumed-role/AWSReservedSSO_lz-sec_abc123/*

    LUU Y VE HAU TO: phan _abc123 do Identity Center sinh, va no DOI khi
    permission set duoc tao lai. Luc do pool tro thanh rong ma khong co
    loi nao - moi PR chi lang le khong du luot duyet. Neu gap, do lai
    bang lenh tren.
  EOT
  type        = list(string)
}

variable "so_nguoi_duyet" {
  description = <<-EOT
    So luot duyet can co de merge duoc PR.

    1 la du cho hau het truong hop. Dat 2 khi muon hai nguoi doc doc lap.

    CodeCommit KHONG cho nguoi tao PR tu duyet PR cua minh, nen 1 da
    nghia la "mot nguoi khac".
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.so_nguoi_duyet >= 1 && var.so_nguoi_duyet <= 10
    error_message = "so_nguoi_duyet trong khoang 1..10."
  }
}
