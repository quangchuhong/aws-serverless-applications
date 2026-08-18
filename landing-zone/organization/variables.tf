variable "region" {
  description = "Region chay Terraform. Organizations la dich vu toan cau, region nao cung duoc."
  type        = string
  default     = "ap-southeast-1"
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
# 1. Organization da ton tai chua
########################################

variable "create_organization" {
  description = <<-EOT
    false = Organization DA CO, Terraform chi doc (data source).
    true  = Terraform tao Organization moi.

    QUAN TRONG: neu account cua ban da bat Organizations roi ma dat
    true thi apply se loi AlreadyInOrganizationException.

    Da co san va muon Terraform quan ly thi phai IMPORT:
      terraform import aws_organizations_organization.this o-xxxxxxxxxx

    Kiem tra hien trang:
      aws organizations describe-organization
  EOT
  type        = bool
  default     = false
}

########################################
# 2. Cay OU
#
# Cau truc nay khop voi pham vi trong landing-zone/permission-sets:
#   Workloads/Non-Production -> scope "nonprod"
#   Workloads/Production     -> scope "prod"
#   Data Analytics           -> scope "analytics"
########################################

variable "ou_structure" {
  description = <<-EOT
    Cay OU. Key = ten OU cap 1, value = danh sach OU con.

    Doi cau truc o day thi PHAI cap nhat scp_attachments cho khop,
    neu khong se co OU khong duoc SCP nao bao ve.
  EOT
  type        = map(list(string))

  default = {
    "Security"       = []
    "Infrastructure" = []
    "Workloads"      = ["Non-Production", "Production"]
    "Data Analytics" = []
    "Sandbox"        = []
    "Suspended"      = []
  }
}

########################################
# 3. Khoa region
########################################

variable "allowed_regions" {
  description = <<-EOT
    Region duoc phep dung. Moi region khac bi SCP chan.

    Vi sao can: gioi han be mat tan cong va gioi han chi phi. Resource
    chay o region ban khong bao gio nhin toi la thu de bi bo quen nhat.

    LUU Y: them region moi thi phai apply lai TRUOC khi dung region do.
  EOT
  type        = list(string)
  default     = ["ap-southeast-1", "us-east-1"]

  validation {
    condition     = length(var.allowed_regions) > 0
    error_message = "Phai co it nhat mot region, neu khong se tu khoa minh ra ngoai."
  }

  validation {
    condition     = contains(var.allowed_regions, "us-east-1")
    error_message = "PHAI co us-east-1: CloudFront, WAF scope CLOUDFRONT, ACM cho CloudFront, va nhieu API billing chi ton tai o day."
  }
}

########################################
# 4. Account mang
#
# Chi account nay duoc tao IGW / NAT / EIP / TGW.
# Xem doc 13.
########################################

variable "network_account_id" {
  description = <<-EOT
    Account ID cua network account.

    De RONG = chua co account network -> SCP khoa internet se ap cho
    MOI account trong pham vi, ke ca account ban dinh dung lam network.
    Dung cho giai doan dau khi chua tach account.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.network_account_id == "" || can(regex("^[0-9]{12}$", var.network_account_id))
    error_message = "Phai la 12 chu so hoac de rong."
  }
}

########################################
# 5. Bat/tat tung SCP
#
# GIOI HAN CUA AWS phai biet truoc:
#   - Toi da 5 SCP gan vao MOT root/OU/account
#     (FullAWSAccess da chiem 1 -> con 4)
#   - Moi SCP toi da 5120 ky tu
#
# ./validate-scp.sh kiem tra ca hai.
########################################

variable "enable_scp" {
  description = <<-EOT
    Bat tung nhom SCP.

    Khuyen nghi khi trien khai that: bat tung cai MOT, apply, roi thu
    lai cac thao tac binh thuong truoc khi bat cai tiep theo. Bat het
    mot luot roi co gi hong thi khong biet do cai nao.
  EOT
  type = object({
    baseline     = optional(bool, true)
    region_lock  = optional(bool, true)
    network_lock = optional(bool, true)
    prod_guard   = optional(bool, true)
  })
  default = {}
}

variable "scp_dry_run" {
  description = <<-EOT
    true = TAO policy nhung KHONG GAN vao dau ca.

    Dung de doc noi dung policy tren console va uoc luong tac dong
    truoc khi that su chan. SCP gan nham co the khoa ca to chuc ra
    ngoai - buoc nay dang gia vai phut.
  EOT
  type        = bool
  default     = false
}

########################################
# 6. Loai tru khoi SCP
########################################

variable "scp_exempt_role_names" {
  description = <<-EOT
    Ten IAM role duoc mien tru khoi SCP baseline va region lock.

    VI SAO CAN: pipeline va cong cu van hanh doi khi phai lam dung
    thu ma SCP chan. Khong co duong mien tru thi nguoi ta se go han
    SCP - mat luon lop bao ve.

    Chi dien ten role (khong phai ARN), vi dieu kien dung
    aws:PrincipalArn voi wildcard account.

    DE RONG neu chua chac - them sau de hon la go ra sau.
  EOT
  type        = list(string)
  default     = []
}
