########################################
# DOC ACCOUNT VENDING - tuy chon, mac dinh TAT
#
# Layer landing-zone/account-baseline biet account nao pham vi nonprod
# - tuc account nao KHONG duoc bat Config recorder, va vi vay PHAI nam
# trong excluded_accounts.
#
# Cho toi truoc file nay, danh sach do di qua mat nguoi: output
# paste_config_detective in ra mot khoi HCL de dan vao tfvars.
#
# ---------------------------------------------------------------
# VI SAO BUOC NAY DE QUEN, VA QUEN THI TON HAI CHUC PHUT
#
# Quy tac la: MOI account ACTIVE phai HOAC nam trong mot OU cua
# recorder_target_ous, HOAC nam trong excluded_accounts. Account roi
# ra ngoai ca hai thi organization rule van bi day xuong no, ngoi
# CREATE_IN_PROGRESS hang chuc phut roi CREATE_FAILED - va keo ca lan
# apply theo.
#
# Account moi sinh ra o mot layer khac, vao mot ngay khac, boi mot
# nguoi khac. Khong co gi noi hai su kien do voi nhau ngoai mot dong
# trong tai lieu - cho toi khi co file nay.
#
# ---------------------------------------------------------------
# MAC DINH TAT: vending_state = {} thi khong doc gi, khong doi gi.
########################################

variable "vending_state" {
  description = <<-EOT
    Backend cua state layer landing-zone/account-baseline.

    DE RONG = khong doc, va layer nay chi dung var.excluded_accounts.

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

  vending_excluded = try(local.vending_raw.config_excluded, [])

  # GOP chu khong THAY. Danh sach go tay co the chua account khong
  # sinh ra tu catalog - account moi vao to chuc bang loi moi chang
  # han.
  excluded_all = distinct(concat(var.excluded_accounts, local.vending_excluded))
}

check "vending_state_doc_duoc" {
  assert {
    condition = !local.vending_on || local.vending_raw != null
    error_message = join(" ", [
      "vending_state da khai nhung khong doc duoc output vending_handles.",
      "Thuong la account-baseline chua apply lai sau khi keo code moi -",
      "output nam trong state, khong nam trong code.",
      "Kiem: cd ../account-baseline && terraform output vending_handles",
      "Layer nay VAN chay, chi dung var.excluded_accounts nhu cu.",
    ])
  }
}
