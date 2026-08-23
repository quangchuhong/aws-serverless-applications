########################################
# CONG TAC CHINH
########################################

variable "enable" {
  description = <<-EOT
    false (mac dinh) -> plan ra 0 resource.

    DOC BANG CHI PHI TRONG README TRUOC KHI DOI THANH true. Day la
    layer duy nhat trong landing-zone/ ton tien dang ke: rieng
    Network Firewall da ~$285/thang moi AZ, chay 24/7.
  EOT
  type        = bool
  default     = false
}

variable "project" {
  description = "Tien to cho moi ten resource"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{2,20}$", var.project))
    error_message = "project chi gom chu thuong, so va dau gach ngang, 2-20 ky tu."
  }
}

variable "region" {
  description = "Region dat hub. PHAI nam trong allowed_regions cua SCP region_lock."
  type        = string
  default     = "ap-southeast-1"
}

variable "owner" {
  description = "Email chiu trach nhiem, gan vao tag"
  type        = string
}

variable "cost_center" {
  description = "Ma cost center, gan vao tag"
  type        = string
  default     = "platform"
}

########################################
# ACCOUNT
########################################

variable "network_account_id" {
  description = <<-EOT
    Account chua TGW va toan bo hub VPC.

    Lay tu: cd ../organization && terraform output account_ids
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.network_account_id))
    error_message = "network_account_id phai la 12 chu so."
  }
}

variable "cross_account_role" {
  description = <<-EOT
    Role assume sang account network.

    OrganizationAccountAccessRole co san o moi account do Organizations
    tao. Neu ban tu quan role rieng thi doi ten o day.
  EOT
  type        = string
  default     = "OrganizationAccountAccessRole"
}

########################################
# AZ
########################################

variable "availability_zones" {
  description = <<-EOT
    AZ dat hub. MOI AZ nhan mot ban sao cua:
      - NAT Gateway              ~$33/thang + data
      - Network Firewall endpoint ~$285/thang
      - subnet tgw/firewall/public

    Nen HAI AZ o moi truong that. MOT AZ chi de thu code - khi AZ do
    hong thi toan bo LZ mat duong ra Internet va mat ca east-west.
  EOT
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]

  validation {
    condition     = length(var.availability_zones) >= 1 && length(var.availability_zones) <= 3
    error_message = "availability_zones phai co 1 den 3 phan tu. Bang CIDR o doc 17 muc 3 chi cap phat cho 2."
  }

  validation {
    condition     = length(distinct(var.availability_zones)) == length(var.availability_zones)
    error_message = "availability_zones co phan tu trung nhau."
  }
}

########################################
# CIDR - theo bang chuan o doc 17 muc 3
#
# Bang do THAY THE moi bang CIDR trong docs 12-16. Doi o day thi
# phai doi ca doc 17, khong lam nguoc lai.
########################################

variable "security_vpc_cidr" {
  description = "security VPC. Doc 17: 10.1.0.0/16"
  type        = string
  default     = "10.1.0.0/16"
}

variable "egress_vpc_cidr" {
  description = "egress VPC. Doc 17: 10.2.0.0/16 (doc 13 ghi 10.1 - da lac hau)"
  type        = string
  default     = "10.2.0.0/16"
}

variable "ingress_vpc_cidr" {
  description = <<-EOT
    ingress VPC. Doc 17: 10.0.0.0/16

    Layer nay CHUA tao ingress VPC, nhung van can CIDR cua no: khi
    bat enable_ingress_route, rtb-security phai co route tinh
    <ingress_vpc_cidr> -> ingress DAT TRUOC 0.0.0.0/0.

    Thieu route do thi goi tra loi cua app cho F5 khop 0.0.0.0/0 va
    bi day sang egress VPC. Trieu chung: request vao toi app, app xu
    ly xong, client khong bao gio nhan duoc phan hoi.
  EOT
  type        = string
  default     = "10.0.0.0/16"
}

# KHONG khai partner_vpc_cidr o day. 3rd-party VPC (doc 17: 10.9.0.0/16)
# chua co trong layer nay, va mot bien khong ai doc la mot bien se lac
# hau ma khong ai biet. Khi them VPC do, route cua no di qua
# extra_security_routes - dung duong ma doc 17 QT4 mo ta.

variable "internal_supernet" {
  description = <<-EOT
    Dai bao trum moi thu noi bo. Dung trong:
      - route "duong ve" o egress/public -> TGW
      - security group cua interface endpoint
      - rule HOME_NET cua Network Firewall

    Rong hon thuc te thi khong sao. Hep hon thi co luong bi dut ma
    khong bao loi.
  EOT
  type        = string
  default     = "10.0.0.0/8"
}

########################################
# FIREWALL
########################################

variable "enable_firewall" {
  description = <<-EOT
    true (mac dinh) -> security VPC + Network Firewall, moi luong
    spoke<->Internet va spoke<->spoke deu bi thanh tra.

    false -> spoke di THANG sang egress VPC. Re hon ~$285/thang moi
    AZ, nhung mat toan bo thanh tra VA mat cach ly east-west: luc do
    khong co gi chan spoke nay goi spoke kia ngoai security group.

    Doc 17 R8 goi day la rang buoc manh nhat cua ca thiet ke. Tat no
    la doi kien truc, khong phai tiet kiem.
  EOT
  type        = bool
  default     = true
}

variable "firewall_mode" {
  description = <<-EOT
    "alert" (mac dinh) -> CHI GHI LOG, khong chan gi.
    "drop"             -> chan that.

    LUON chay "alert" truoc it nhat mot tuan. Doc alert log de biet
    thuc te ai dang goi ai, roi moi viet rule va chuyen sang "drop".
    Bat "drop" ngay tu dau la cach nhanh nhat de lam dut mot luong
    khong ai biet la co ton tai.
  EOT
  type        = string
  default     = "alert"

  validation {
    condition     = contains(["alert", "drop"], var.firewall_mode)
    error_message = "firewall_mode chi nhan \"alert\" hoac \"drop\"."
  }
}

variable "east_west_rules" {
  description = <<-EOT
    Spoke nao duoc goi spoke nao.

    DAY LA CHO DUY NHAT can sua khi muon mo/dong ket noi VPC-to-VPC.
    Route table KHONG doi - rtb-spokes chi co dung mot dong
    0.0.0.0/0 -> security, va no da phu moi truong hop.
  EOT
  type = list(object({
    from_cidr = string
    to_cidr   = string
    port      = number
    note      = string
  }))
  default = []
}

variable "egress_allowed_domains" {
  description = <<-EOT
    Domain duoc phep goi ra Internet, khop theo TLS SNI / HTTP Host.

    Dau "." o dau nghia la ca subdomain: ".amazonaws.com" khop
    "s3.ap-southeast-1.amazonaws.com".

    Chi co tac dung khi firewall_mode = "drop". O che do "alert" thi
    moi thu van di qua, chi khac la co log.
  EOT
  type        = list(string)
  default = [
    ".amazonaws.com",
    ".amazonlinux.com",
    ".docker.io",
    ".ubuntu.com",
  ]
}

########################################
# INTERFACE ENDPOINT
########################################

variable "enable_interface_endpoints" {
  description = <<-EOT
    Dat interface endpoint TRONG security VPC va chia cho moi spoke
    qua Private Hosted Zone.

    Vi sao dat o security VPC chu khong o tung spoke: dat o tung
    spoke thi nhan len theo so spoke (moi endpoint ~$7.3/thang moi
    AZ), va luong khong di qua firewall. Dat o day thi spoke -> TGW
    -> firewall -> local -> endpoint: duoc thanh tra ma khong ton
    them chang TGW nao.
  EOT
  type        = bool
  default     = true
}

variable "interface_endpoint_services" {
  description = <<-EOT
    Dich vu can interface endpoint. Moi cai ~$7.3/thang moi AZ cong
    phi du lieu - dung them cho "cho chac".

    Bon cai mac dinh la toi thieu de van hanh mot spoke KHONG co
    duong ra Internet: SSM can ca ba (ssm, ssmmessages, ec2messages)
    de Session Manager hoat dong, va logs de gui CloudWatch Logs.

    S3 va DynamoDB KHONG nam o day - chung dung gateway endpoint,
    MIEN PHI, va tao o tung spoke.
  EOT
  type        = list(string)
  default     = ["ssm", "ssmmessages", "ec2messages", "logs"]
}

########################################
# CHIA SE VA NOI SPOKE
########################################

variable "share_tgw_with_org" {
  description = <<-EOT
    Chia se TGW cho toan to chuc qua RAM.

    Can ram.amazonaws.com trong aws_service_access_principals ben
    layer organization - da co san trong danh sach mac dinh.

    Tat cai nay thi account workload khong nhin thay TGW va khong tu
    attach duoc.
  EOT
  type        = bool
  default     = true
}

variable "spoke_attachments" {
  description = <<-EOT
    Attachment do ACCOUNT WORKLOAD tu tao, can duoc noi vao route
    table. Khoa la ten cho de doc, gia tri la ID attachment.

      spoke_attachments = {
        app-dev  = "tgw-attach-0a1b2c3d4e5f60718"
        app-prod = "tgw-attach-0a1b2c3d4e5f60719"
      }

    Vi sao phai khai tay: attachment nam o account khac nen layer nay
    khong tao ra chung, va discovery dong bang data source se lam
    count/for_each thanh "known after apply" - plan khong doc duoc.

    Lay danh sach (chay o account network):

      aws ec2 describe-transit-gateway-attachments \
        --filters Name=transit-gateway-id,Values=<tgw-id> \
                  Name=resource-type,Values=vpc \
        --query 'TransitGatewayAttachments[].[TransitGatewayAttachmentId,ResourceOwnerId,State]' \
        --output table

    CHUA NOI VAO DAY = attachment ton tai nhung khong thuoc route
    table nao. Khong loi, khong canh bao, va khong mot goi tin nao
    di qua duoc.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for id in values(var.spoke_attachments) : can(regex("^tgw-attach-[0-9a-f]{8,}$", id))
    ])
    error_message = "Moi gia tri phai la ID attachment dang tgw-attach-xxxxxxxx."
  }
}

variable "extra_security_routes" {
  description = <<-EOT
    Route tinh THEM vao rtb-security. Khoa la CIDR dich, gia tri la
    ID attachment.

    Doc 17 QT4: them mot VPC moi vao network account = them mot route
    tinh vao rtb-security. Day la buoc hay quen nhat khi mo rong, va
    quen no thi luong toi VPC do khop 0.0.0.0/0 roi di ra egress.

    rtb-security la bang DUY NHAT can route tinh cho dich khong phai
    spoke, vi spoke da vao bang nay bang propagation.
  EOT
  type        = map(string)
  default     = {}
}

variable "enable_ingress_route" {
  description = <<-EOT
    Them route tinh <ingress_vpc_cidr> -> ingress_attachment_id vao
    rtb-security.

    Chi bat khi da co ingress VPC that. Bat ma khong dien
    ingress_attachment_id thi precondition se chan apply.
  EOT
  type        = bool
  default     = false
}

variable "ingress_attachment_id" {
  description = "ID attachment cua ingress VPC. Bat buoc khi enable_ingress_route = true."
  type        = string
  default     = ""
}

########################################
# LOG
########################################

variable "firewall_log_retention_days" {
  description = <<-EOT
    So ngay giu log firewall trong S3 truoc khi xoa han.

    Log FLOW rat nhieu - moi phien mot dong. 90 ngay la du cho dieu
    tra su co thong thuong; dai hon thi chuyen sang log archive
    account thay vi giu o day.
  EOT
  type        = number
  default     = 90

  validation {
    condition     = var.firewall_log_retention_days >= 7
    error_message = "Giu duoi 7 ngay thi khong dieu tra duoc gi."
  }
}
