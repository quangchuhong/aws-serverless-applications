variable "enable" {
  description = <<-EOT
    Bat layer nay.

    MAC DINH TAT, va nen giu tat cho toi khi tra loi duoc mot cau:

      "Doi ung dung co con quyen tao resource truc tiep khong?"

    Con quyen thi TagOption khong ep duoc gi - ho tao thang bang
    console, khong di qua catalog. Layer nay chi la mot portfolio
    rong khong ai dung.

    No chi co nghia khi di kem viec THU HOI quyen tao truc tiep va
    thay bang product trong catalog.
  EOT
  type        = bool
  default     = false
}

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

variable "management_account_id" {
  description = <<-EOT
    ID management account. Chi dung cho check canh bao khi ban dang
    dung layer nay o management - de rong thi bo qua kiem tra do.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.management_account_id == "" || can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "Phai la 12 chu so hoac de rong."
  }
}

########################################
# 1. TagOption
########################################

variable "tag_options" {
  description = <<-EOT
    Key -> danh sach gia tri hop le.

    SO LUONG GIA TRI QUYET DINH HANH VI:

      1 gia tri    tag TU GAN, nguoi launch khong thay va khong bo duoc
      2 tro len    nguoi launch BUOC PHAI CHON mot - khong chon thi
                   khong tao duoc resource

    Do la ly do CostCenter nen liet ke ma phong ban that: mot danh
    sach ma bat nguoi ta chon dung hon han mot o trong bat ho go.

    Mac dinh de CostCenter RONG vi ma phong ban la thu rieng cua tung
    to chuc - key nao co list rong thi khong sinh TagOption nao ca.

    Environment giu dung bon gia tri cua doc 11 muc 2, khop voi
    tag_policy_keys ben layer organization. Hai cho lech nhau thi
    nguoi dung chon duoc mot gia tri ma tag policy bao la sai.
  EOT
  type        = map(list(string))

  default = {
    Environment = ["dev", "staging", "prod", "sandbox"]
    ManagedBy   = ["service-catalog"]
    CostCenter  = []
  }

  validation {
    condition = alltrue([
      for _, values in var.tag_options : length(values) == length(distinct(values))
    ])
    error_message = "Mot key khong duoc co gia tri trung lap."
  }
}

########################################
# 2. Portfolio
########################################

variable "portfolios" {
  description = <<-EOT
    Portfolio can tao. Key thanh hau to cua ten: <project>-<key>.

    Mot portfolio moi doi tuong dung, khong phai mot portfolio cho
    tat ca: quyen truy cap va viec chia se deu o muc portfolio, nen
    gop chung nghia la khong tach duoc ai thay gi.
  EOT
  type = map(object({
    description = string
  }))

  default = {
    app-team = { description = "Resource doi ung dung tu phuc vu" }
  }
}

variable "portfolio_provider_name" {
  description = "Ten hien thi cua ben cung cap portfolio - nguoi dung thay ten nay trong console."
  type        = string
  default     = "Platform Engineering"
}

########################################
# 3. Chia se
########################################

variable "share_ou_arns" {
  description = <<-EOT
    ARN cua OU duoc chia portfolio. RONG = khong chia cho ai, chi
    dung duoc trong chinh account hub.

    Chia theo OU thi account TAO SAU trong OU do tu thay portfolio -
    cung khuon voi auto_deployment cua StackSet.

    Lay ARN (khong phai ID):
      aws organizations list-organizational-units-for-parent \
        --parent-id <root-id> --query 'OrganizationalUnits[].[Name,Arn]' \
        --output table

    Layer nay LUON dat share_tag_options = true. Mac dinh cua AWS la
    false, va thieu no thi portfolio sang toi noi ma TagOption o lai -
    nguoi ben do launch product khong bi hoi tag nao.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for a in var.share_ou_arns : can(regex("^arn:aws[a-z-]*:organizations::", a))
    ])
    error_message = "Phai la ARN cua OU, khong phai ID. Bat dau bang arn:aws:organizations::"
  }
}

########################################
# 4. Launch role
########################################

variable "create_launch_role" {
  description = <<-EOT
    Tao IAM role de Service Catalog dung khi tao resource cua product.

    Bat gan nhu luon dung. Khong co launch constraint thi nguoi launch
    phai TU CO QUYEN tren moi dich vu ma product tao ra - ma co quyen
    do roi thi ho tao thang duoc, va catalog thanh hinh thuc.

    Tat khi ban da co san role rieng va muon tu quan.
  EOT
  type        = bool
  default     = true
}

variable "launch_role_policy_arns" {
  description = <<-EOT
    Policy gan vao launch role.

    CHU Y PHAM VI: role nay tao resource THAY MAT nguoi dung, nen quyen
    cua no la tran tren cua moi thu product lam duoc. Gan
    AdministratorAccess vao day nghia la bat ky ai launch duoc product
    deu gian tiep co quyen admin.

    Nen viet policy rieng, chi du cho dung nhung product ban that su
    dua vao catalog. Mac dinh de RONG de khong ai vo tinh dung mot
    role qua rong.

    Role van can quyen CloudFormation - do la thu THUC SU tao resource.
  EOT
  type        = list(string)
  default     = []
}
