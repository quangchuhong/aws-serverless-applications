variable "enable" {
  description = <<-EOT
    Bat/tat ca layer. Mac dinh FALSE.

    false -> terraform plan ra 0 resource, khong cham vao gi.
  EOT
  type        = bool
  default     = false
}

variable "region" {
  description = <<-EOT
    Region dat StackSet. KHONG phai pham vi quet.

    StackSet chi can MOT stack instance moi account; Lambda ben trong
    tu quet cac region trong var.sweep_regions. Nen day chi la noi dat
    resource.
  EOT
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
# 1. Quet default VPC
########################################

variable "baseline_target_ous" {
  description = <<-EOT
    OU duoc trien khai baseline. Lay ID bang:
      cd ../organization && terraform output ou_ids

    Nen dua VAO DAY MOI OU chua account thuc, ke ca Sandbox va
    Non-Production - khac han config-detective.

    Ly do khac nhau: Config tinh tien theo khoi luong ghi nen phai
    chon loc. Xoa default VPC thi mien phi va lam MOT LAN, nen bo sot
    mot OU chi de lai lo hong chu khong tiet kiem duoc gi.

    MANAGEMENT ACCOUNT NAM NGOAI TAM VOI - khong phai lua chon.

    StackSet SERVICE_MANAGED trien khai theo cay to chuc, va AWS loai
    management account ra khoi moi dot trien khai do. Management lai
    nam truc tiep duoi root, khong thuoc OU nao. Khai them root id vao
    day cung KHONG toi duoc no. Do duoc o doc 22 loi 59, va cach no
    bao loi rat te: khong co dong nao trong list-stack-instances cho
    account do, khong StatusReason nao.

    Nghia la: default VPC o management KHONG BAO GIO bi quet, o moi
    region. Muon xoa thi lam bang tay, tu chinh account do.

    Truoc khi xoa, kiem xem co ai dang dung khong - default VPC hay
    duoc dung cho nhung thu dung len nhanh roi o lai:
      aws ec2 describe-instances --filters Name=vpc-id,Values=<vpc-id>
      aws eks list-clusters
  EOT
  type        = list(string)
  default     = []
}

variable "sweep_regions" {
  description = <<-EOT
    Region can xoa default VPC.

    ===============================================================
    PHAI KHOP VOI allowed_regions BEN layer organization.

    region_lock SCP chan MOI hanh dong ngoai allowed_regions - ke ca
    ec2:DeleteVpc. Nen Lambda KHONG xoa duoc default VPC o region bi
    khoa, va se ghi "SKIP" cho region do.

    Do KHONG phai lo hong: default VPC o region bi khoa la VO HAI.
    Khong ai tao duoc gi o do, va IGW nam san cung khong dung duoc -
    ec2:RunInstances, ec2:CreateNetworkInterface deu bi region_lock
    tu choi truoc.

    Bo region_lock ve sau thi PHAI chay lai layer nay cho cac region
    moi mo.
    ===============================================================
  EOT
  type        = list(string)
  default     = ["ap-southeast-1", "us-east-1"]

  validation {
    condition     = length(var.sweep_regions) > 0
    error_message = "Phai co it nhat mot region."
  }
}

variable "sweep_version" {
  description = <<-EOT
    Doi gia tri nay de BUOC quet lai o moi account.

    Custom resource cua CloudFormation chi chay lai khi thuoc tinh
    doi. Khong co bien nay thi sau lan tao dau tien no khong bao gio
    chay nua - ke ca khi ban them region vao sweep_regions.

    Dung khi: them region, hoac nghi ngo co default VPC moi xuat hien.
  EOT
  type        = string
  default     = "1"
}

########################################
# 2. Vending account moi - MAC DINH TAT
########################################

variable "create_accounts" {
  description = <<-EOT
    Account Terraform tao moi, dat THANG vao dung OU.

    Tao thang vao OU thi khong con buoc move-account, tuc khong con
    cho de quen.

    ===============================================================
    GAN NHU KHONG HOAN TAC DUOC. Doc het truoc khi dien.

    - Account KHONG XOA duoc, chi DONG duoc, va dong xong phai cho
      90 ngay moi bien mat khoi to chuc.
    - Email cua account la DUY NHAT VINH VIEN o pham vi AWS toan cau.
      Dong account roi cung KHONG dung lai duoc email do.
    - terraform destroy voi close_on_deletion = true se DONG account.
      Mac dinh cua layer nay la false: destroy chi go khoi state.

    De RONG neu chua chac. Tao tay bang create-account cung duoc -
    chi mat them buoc move-account.
    ===============================================================

    Dung plus-addressing de khong can nhieu hop thu:
      ban+lz-network-01@gmail.com
    AWS coi day la email khac nhau; thu van ve mot hop.
  EOT
  type = map(object({
    email     = string
    parent_id = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for _, a in var.create_accounts : can(regex("^ou-|^r-", a.parent_id))
    ])
    error_message = "parent_id phai la OU ID (ou-...) hoac root ID (r-...). Lay bang: cd ../organization && terraform output ou_ids"
  }

  validation {
    condition = alltrue([
      for _, a in var.create_accounts : can(regex("@", a.email))
    ])
    error_message = "email khong hop le."
  }
}

variable "close_accounts_on_destroy" {
  description = <<-EOT
    true = terraform destroy se DONG account that.

    MAC DINH FALSE, va nen giu false.

    false thi destroy chi go account khoi state - account van chay,
    van trong to chuc. Do la hanh vi an toan hon han cho mot thu
    khong tao lai duoc.
  EOT
  type        = bool
  default     = false
}

########################################
# 3. Ban do pham vi - de sinh cau hinh cho layer khac
########################################

variable "account_scopes" {
  description = <<-EOT
    Account ID -> pham vi, dung SINH SAN cau hinh cho layer khac.

    Layer nay KHONG sua duoc terraform.tfvars cua layer khac. Nhung
    no biet du de sinh ra khoi HCL cho ban dan vao, va de canh bao
    khi co account chua duoc khai o dau ca.

    Gia tri hop le:
      analytics | nonprod | prod | none

    "none" = account ha tang (network, security, log archive) - chi
    nhan permission set pham vi "all", khong thuoc pham vi workload
    nao.

    Xem output paste_permission_sets va unmapped_accounts.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for _, s in var.account_scopes :
      contains(["analytics", "nonprod", "prod", "none"], s)
    ])
    error_message = "Chi chap nhan: analytics, nonprod, prod, none."
  }
}

########################################
# 4. Catalog yeu cau tao account
########################################

variable "catalog_dir" {
  description = "Thu muc chua accounts.yaml, tuong doi voi layer nay"
  type        = string
  default     = "catalog"
}

variable "ou_ids" {
  description = <<-EOT
    TEN OU -> OU ID. Catalog khai bang ten, layer nay giai thanh ID.

    VI SAO KHONG KHAI ID THANG TRONG CATALOG

    ou-abc1-x9y8z7w6 go nham mot ky tu van la mot chuoi hop le. No
    tro vao mot OU khac - hoac khong OU nao - va Terraform bao mot
    loi API khong nhac gi toi viec ban go nham.

    Ten thi doi chieu duoc, va plan dung lai kem danh sach ten hop le.

    Lay bang:
      cd ../organization && terraform output ou_ids
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for _, id in var.ou_ids : can(regex("^ou-", id))])
    error_message = "Moi gia tri phai la OU ID bat dau bang 'ou-'. Root ID (r-...) khong duoc - account dat thang vao root chi con SCP o root."
  }
}

########################################
# 5. Hardening cap account
#
# Bon thu AWS de MO SAN khi mo mot account moi. Khong cai nao co
# resource CloudFormation goc, nen ca bon di cung Lambda cua
# vpc-sweep - mot stack instance moi account, khong phai bon.
#
# Tat ca deu MIEN PHI va deu KHONG the hien ra o bat cu bang gia nao.
# Chung cung khong bao loi khi thieu: mot account khong co cai nao
# trong so nay van chay hoan toan binh thuong.
########################################

variable "harden_password_policy" {
  description = <<-EOT
    Dat chinh sach mat khau IAM cho account moi.

    Mac dinh cua AWS: dai toi thieu 6 ky tu, khong doi ky tu dac biet,
    khong het han, dung lai mat khau cu duoc. Do la mac dinh tu 2011
    va no chua bao gio doi.

    Chi anh huong IAM user - Identity Center co chinh sach rieng. Nen
    trong mot LZ dung Identity Center thi day la lop bao ve cho DUNG
    nhung IAM user le ra khong nen ton tai.
  EOT
  type        = bool
  default     = true
}

variable "password_min_length" {
  type    = number
  default = 14

  validation {
    condition     = var.password_min_length >= 8 && var.password_min_length <= 128
    error_message = "AWS chi nhan 8-128."
  }
}

variable "password_max_age_days" {
  description = "0 = khong het han. AWS nhan 1-1095."
  type        = number
  default     = 90
}

variable "password_reuse_prevention" {
  description = "So mat khau cu khong duoc dung lai. AWS nhan 1-24."
  type        = number
  default     = 24
}

variable "harden_s3_public_access_block" {
  description = <<-EOT
    Bat Block Public Access o CAP ACCOUNT cho S3.

    Khac han voi cai dat tren tung bucket: cap account de len TAT CA
    bucket, ke ca bucket tao sau, ke ca bucket do mot template hay
    mot doi khac tao.

    Day la mot trong vai cai nut hiem hoi trong AWS ma bat len la bit
    duoc CA MOT LOAI su co, khong phai mot su co.
  EOT
  type        = bool
  default     = true
}

variable "harden_ebs_encryption" {
  description = <<-EOT
    Bat ma hoa EBS mac dinh, o MOI region trong sweep_regions.

    Theo region, khong theo account - nen bo sot mot region la de lai
    dung cai lo hong dang bit o cac region khac.

    Dung khoa mac dinh cua AWS (aws/ebs). Muon khoa rieng thi phai
    dat them, va viec do nen lam co y chu khong nen mac dinh: mat
    khoa CMK la mat du lieu.
  EOT
  type        = bool
  default     = true
}

variable "harden_default_security_group" {
  description = <<-EOT
    Go sach rule cua default security group o moi region.

    Default security group KHONG XOA DUOC. No luon ton tai trong moi
    VPC va mac dinh cho phep MOI luu luong giua cac ENI dung chung no
    - tuc mot mang phang an trong moi VPC, ke ca VPC do chinh doi ban
    tao. Ai quen khai security group thi ENI roi vao no.

    Cach duy nhat la go sach rule. AWS Config co rule
    vpc-default-security-group-closed cho dung viec nay, nhung Config
    chi BAO; cai nay SUA.
  EOT
  type        = bool
  default     = true
}

variable "availability_zones" {
  description = <<-EOT
    AZ dat subnet cho VPC cua account workload. TOI THIEU 2.

    De rong = lay hai AZ dau cua region (<region>a, <region>b).

    Day la TEN AZ. Ten "ap-southeast-1a" tro vao mot AZ VAT LY khac
    nhau o moi account - AWS xao tron co chu dich de tai khong don ve
    mot AZ. Voi mot VPC nen thi khong sao. Voi thu can dat cung AZ vat
    ly voi account khac (vi du de tranh phi cross-AZ) thi phai dung
    AZ ID, va luc do khong khai o day duoc nua.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) >= 2
    error_message = "Toi thieu 2 AZ, hoac de rong de lay mac dinh."
  }
}

variable "network_handles" {
  description = <<-EOT
    Handle tu layer `network`. Dan tu output cua no.

      cd ../network && terraform output network_handles

    De RONG thi VPC van duoc tao nhung KHONG noi vao luoi: khong TGW,
    khong DNS tap trung. check "spokes_have_a_transit_gateway" noi ra
    truong hop do luc plan.

    VI SAO DAN TAY CHU KHONG DOC REMOTE STATE

    Layer nay chay o MANAGEMENT, layer network chay o account network.
    Doc state cua nhau doi mot duong quyen giua hai account chi de
    lay ba chuoi khong bao gio doi. Dan tay thi ranh gioi ro rang, va
    ba chuoi do di qua mot lan review.
  EOT

  type = object({
    transit_gateway_id = optional(string, "")
    dns_profile_id     = optional(string, "")
    internal_supernet  = optional(string, "10.0.0.0/8")
  })
  default = {}
}
