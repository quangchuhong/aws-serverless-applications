########################################
# DOC ACCOUNT VENDING - tuy chon, mac dinh TAT
#
# Layer landing-zone/account-baseline tao account va dung VPC cho
# chung. Hai thu no biet ma layer nay can:
#
#   spokes     ten -> { cidr, account_id, ou_id, manual_vpc = true }
#   tgw_share  account ID can THAY TGW de tu cam attachment
#
# Cho toi truoc file nay, ca hai di qua MAT NGUOI: output paste_spokes
# ben kia in ra mot khoi HCL, nguoi ta dan vao terraform.tfvars.
#
# ---------------------------------------------------------------
# VI SAO PHAI BO CACH DAN TAY
#
# Khong phai vi go phim cham. Vi buoc dan co MOT KIEU HONG IM LANG:
# dan khoi `spokes = { ... }` CANH khoi spokes dang co thay vi VAO
# TRONG no. Hai muc do thanh khoa cap cao nhat cua tfvars, va
# Terraform chi keu:
#
#   Warning: Value for undeclared variable
#
# roi chay tiep. `Apply complete. 0 added, 0 changed.` Va hai account
# khong bao gio duoc noi vao route table. Da xay ra that - xem doc 22
# muc 7ar.
#
# ---------------------------------------------------------------
# TFVARS THANG, KHONG PHAI STATE
#
# merge() dat var.spokes SAU, nen mot spoke khai tay de len spoke
# doc tu state. Ly do: var.spokes la thu nguoi ta go va review duoc;
# state la thu suy ra. Khi hai ben noi khac nhau, thu nguoi ta go
# thang.
#
# Nhung im lang de len nhau la mot cach hong khac, nen check
# "vending_khong_de_len_tfvars" o duoi keu ten moi khoa trung.
#
# ---------------------------------------------------------------
# MAC DINH TAT
#
# vending_state = {} thi file nay khong doc gi va khong doi gi.
# Moi trien khai dang chay bang tfvars van chay y nguyen.
########################################

variable "vending_state" {
  description = <<-EOT
    Backend cua state layer landing-zone/account-baseline.

    DE RONG = khong doc, va layer nay chi dung var.spokes nhu cu.

    Dang gia tri giong het var.state_config ben network/ops:

      vending_state = {
        backend = "s3"
        bucket  = "..."
        key     = "account-baseline/terraform.tfstate"
        region  = "ap-southeast-1"
        profile = "default"      # neu state nam o account khac
      }

    Lay khoa:
      cd ../tf-backend && terraform output layers

    QUYEN DOC STATE LA QUYEN DOC MOI OUTPUT cua layer do - trong do
    co danh sach account va email. Khong phai bi mat lon, nhung cung
    khong phai thu de mo rong ma khong nghi.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition = (
      length(var.vending_state) == 0
      || contains(["s3", "local"], try(var.vending_state.backend, ""))
    )
    error_message = "vending_state phai co khoa 'backend' la \"s3\" hoac \"local\" - hoac de rong han."
  }
}

locals {
  vending_on = length(var.vending_state) > 0

  # backend tach ra khoi phan con lai: terraform_remote_state nhan
  # backend rieng, config rieng.
  vending_backend = try(var.vending_state.backend, "s3")

  ####################################
  # BO `profile` KHI PIPELINE CHAY
  #
  # `profile` trong vending_state ton tai cho NGUOI chay tay: ho dung
  # credential cua account mang, nen doc state o bucket cua account
  # management can mot profile khac.
  #
  # CodeBuild thi nguoc han: credential goc CUA NO da la management -
  # provider moi la cai nhay sang account mang bang assume_role. Nen
  # o do khong nhung khong can profile, ma con KHONG THE co: container
  # khong co ~/.aws/config, va terraform_remote_state dung lai voi
  #
  #   Error: failed to get shared config profile, default
  #
  # mot cau khong nhac gi toi vending_state lan CodeBuild.
  #
  # assume_role_arn khac rong la dau hieu chac chan "dang chay trong
  # pipeline" - chinh no la thu tach hai danh tinh ra. Dung no de bo
  # profile, thay vi them mot bien nua de nguoi ta phai nho dat.
  ####################################
  vending_config = {
    for k, v in var.vending_state : k => v
    if k != "backend" && !(var.assume_role_arn != "" && k == "profile")
  }
}

data "terraform_remote_state" "vending" {
  count = local.vending_on ? 1 : 0

  backend = local.vending_backend
  config  = local.vending_config
}

locals {
  # try() hai lop: state co the doc duoc nhung chua co output nay -
  # account-baseline chua apply lai sau khi keo code moi ve. Truong
  # hop do KHONG duoc lam hong plan cua layer nay; check ben duoi noi
  # ra thay vi de mot loi "attribute does not exist" kho hieu.
  vending_raw = local.vending_on ? try(
    data.terraform_remote_state.vending[0].outputs.vending_handles,
    null
  ) : null

  vending_spokes = try(local.vending_raw.spokes, {})
  vending_share  = try(local.vending_raw.tgw_share, [])

  # Khoa co o CA HAI nguon. Khong chan - tfvars van thang - nhung
  # phai noi ra.
  vending_dupes = sort([
    for k in keys(local.vending_spokes) : k if contains(keys(var.spokes), k)
  ])

  ####################################
  # HAI TAP HOP THAT SU DUOC DUNG
  #
  # Moi cho trong file khac tham chieu var.spokes /
  # var.share_tgw_with_accounts deu phai doi sang hai local nay.
  ####################################
  spokes_all = merge(local.vending_spokes, var.spokes)

  share_tgw_all = distinct(concat(var.share_tgw_with_accounts, local.vending_share))
}

########################################
# KIEM TRA CHEO
########################################

check "vending_state_doc_duoc" {
  assert {
    condition = !local.vending_on || local.vending_raw != null
    error_message = join(" ", [
      "vending_state da khai nhung khong doc duoc output vending_handles.",
      "Hai nguyen nhan: (1) account-baseline chua apply lai sau khi keo code moi -",
      "output nam trong state, khong nam trong code; (2) sai khoa hoac sai bucket.",
      "Kiem: cd ../account-baseline && terraform output vending_handles",
      "Layer nay VAN chay - no chi dung var.spokes nhu khi chua bat vending.",
    ])
  }
}

########################################
# CIDR TRUNG GIUA HAI NGUON
#
# var.spokes co validation block; spoke doc tu state thi KHONG - khoi
# validation chi chay tren bien, khong chay tren local.
#
# Trong tung nguon thi da co nguoi kiem: lint.sh ben account-baseline
# doi chieu CIDR cua ca catalog, con tfvars di qua review. Cai chua ai
# kiem la GIUA hai nguon - va do dung la cho de trung nhat, vi hai ben
# khong nhin thay nhau.
#
# Hai spoke trung dai trong mot luoi TGW thi route table khong phan
# biet duoc, va sua nghia la XOA MOT VPC.
#
# So sanh dia chi mang (cidrhost(cidr, 0)) chu khong so chuoi:
# "10.12.0.0/16" va "10.12.0.0/17" la hai chuoi khac nhau. Phep nay
# bat duoc trung y het nhau va trung dia chi mang; long nhau khac do
# dai thi khong - HCL khong co ham nao lam duoc viec do gon gang, va
# ca thiet ke nay dung /16 dong deu.
########################################
locals {
  vending_cidr_dupes = sort([
    for addr, ks in {
      for k, v in local.spokes_all : cidrhost(v.cidr, 0) => k...
    } : "${addr} (${join(", ", ks)})"
    if length(ks) > 1
  ])
}

check "spoke_khong_trung_dai" {
  assert {
    condition = length(local.vending_cidr_dupes) == 0
    error_message = join(" ", [
      "Hai spoke dung chung mot dai dia chi:", join(" | ", local.vending_cidr_dupes),
      ". Trong mot luoi TGW thi route table khong phan biet duoc chung, va sua",
      "nghia la XOA MOT VPC. Kiem ca hai nguon: var.spokes trong terraform.tfvars,",
      "va catalog/accounts.yaml ben account-baseline.",
    ])
  }
}

check "vending_khong_de_len_tfvars" {
  assert {
    condition = length(local.vending_dupes) == 0
    error_message = join(" ", [
      "Spoke khai o CA HAI cho:", join(", ", local.vending_dupes),
      "- vua trong var.spokes cua terraform.tfvars, vua trong catalog cua",
      "account-baseline. tfvars dang THANG, nen gia tri trong catalog bi bo qua.",
      "Do khong hong ngay, nhung hai nguon su that cho mot spoke se lech nhau",
      "vao ngay ai do sua mot ben. Bo khoi tfvars di - catalog la duong chinh.",
    ])
  }
}
