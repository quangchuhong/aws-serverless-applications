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
