########################################
# DOC ACCOUNT VENDING - tuy chon, mac dinh TAT
#
# Layer landing-zone/account-baseline biet account moi thuoc pham vi
# nao - truong `scope` la BAT BUOC trong catalog, va lint.sh chan neu
# thieu. Layer nay can dung thong tin do de gan permission set.
#
# Cho toi truoc file nay, no di qua mat nguoi: output
# paste_permission_sets in ra khoi HCL de dan vao tfvars.
#
# ---------------------------------------------------------------
# BO QUA BUOC NAY THI KHONG AI VAO DUOC ACCOUNT MOI
#
# Va hau qua khong dung o do. Nguoi can vao mot account khong vao
# duoc se di tim duong khac, va duong khac o AWS thuong la root user
# cua chinh account do - dung cai ma ca landing zone nay dung len de
# khong ai phai cham toi.
#
# Trieu chung khong phai mot loi. No la mot cau hoi trong Slack.
#
# ---------------------------------------------------------------
# MAC DINH TAT: vending_state = {} thi khong doc gi, khong doi gi.
########################################

variable "vending_state" {
  description = <<-EOT
    Backend cua state layer landing-zone/account-baseline.

    DE RONG = khong doc, va layer nay chi dung var.accounts_by_scope.

      vending_state = {
        backend = "s3"
        bucket  = "..."
        key     = "account-baseline/terraform.tfstate"
        region  = "ap-southeast-1"
      }

    Lay khoa: cd ../tf-backend && terraform output layers
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

  # `profile` KHONG duoc khai o layer nay.
  #
  # Layer nay chay o CHINH account management, va state cua
  # account-baseline cung nam o account management. Hai dau cung mot
  # account nghia la credential dang chay da doc duoc state - profile
  # khong them gi.
  #
  # Nhung no pha duoc: CodeBuild khong co ~/.aws/config, nen
  # terraform_remote_state dung lai voi
  #
  #   Error: failed to get shared config profile, default
  #
  # mot cau khong nhac gi toi vending_state, toi layer nay, hay toi
  # CodeBuild. Chan o day de no hong ngay tren may nguoi khai, kem ten
  # khoa - thay vi hong o stage E cua pipeline vai ngay sau.
  validation {
    condition     = !contains(keys(var.vending_state), "profile")
    error_message = "Bo khoa 'profile' khoi vending_state. Layer nay chay o chinh account management - noi state nam - nen profile khong bao gio can, va khai no se lam pipeline hong voi mot thong bao khong lien quan gi toi day."
  }
}

locals {
  vending_on      = length(var.vending_state) > 0
  vending_backend = try(var.vending_state.backend, "s3")
  vending_config  = { for k, v in var.vending_state : k => v if k != "backend" }
}

data "terraform_remote_state" "vending" {
  count = local.vending_on ? 1 : 0

  backend = local.vending_backend
  config  = local.vending_config
}

locals {
  vending_raw = local.vending_on ? try(
    data.terraform_remote_state.vending[0].outputs.vending_handles,
    null
  ) : null

  vending_by_scope = try(local.vending_raw.by_scope, {})

  ####################################
  # GOP THEO TUNG PHAM VI
  #
  # concat + distinct chu khong merge(): merge() tren map cua LIST se
  # thay ca list, nen mot pham vi khai o tfvars se xoa sach phan doc
  # tu catalog. Day la kieu hong im lang - plan chi bao vai assignment
  # bien mat, khong bao vi sao.
  ####################################
  by_scope_all = {
    for s in distinct(concat(
      keys(var.accounts_by_scope),
      keys(local.vending_by_scope),
    )) :
    s => distinct(concat(
      try(var.accounts_by_scope[s], []),
      try(local.vending_by_scope[s], []),
    ))
  }
}

check "vending_state_doc_duoc" {
  assert {
    condition = !local.vending_on || local.vending_raw != null
    error_message = join(" ", [
      "vending_state da khai nhung khong doc duoc output vending_handles.",
      "Thuong la account-baseline chua apply lai sau khi keo code moi -",
      "output nam trong state, khong nam trong code.",
      "Kiem: cd ../account-baseline && terraform output vending_handles",
      "Layer nay VAN chay, chi dung var.accounts_by_scope nhu cu.",
    ])
  }
}
