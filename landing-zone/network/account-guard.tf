########################################
# CHOT CHAN ACCOUNT
#
# Layer nay khong assume role. No dung thang credential trong moi
# truong, va do la thu de doi nhat trong ca quy trinh.
#
# Doi shell sang account khac roi chay lai: Terraform refresh, khong
# thay TGW o account moi, ket luan no da bi xoa, va TAO MOI. Hai bo
# ha tang o hai account - mot trong state, mot mo coi - va khong mot
# thong bao nao. Da xay ra HAI LAN trong mot dem.
#
# Dat o resource rieng chu khong o mot resource that: precondition
# tren mot resource chi chay khi resource do duoc tinh toi, va ta muon
# plan dung NGAY, truoc moi loi goi API tao ha tang.
########################################

resource "terraform_data" "account_guard" {
  input = {
    expected = var.expected_account_id
    actual   = data.aws_caller_identity.current.account_id
  }

  lifecycle {
    precondition {
      condition = (
        var.expected_account_id == ""
        || data.aws_caller_identity.current.account_id == var.expected_account_id
      )
      error_message = join(" ", [
        "SAI ACCOUNT.",
        "expected_account_id = ${var.expected_account_id},",
        "credential dang dung thuoc account",
        "${data.aws_caller_identity.current.account_id}.",
        "Layer nay KHONG assume role - chay tiep se tao mot bo ha tang",
        "THU HAI o account dang dung, va bo cu thanh mo coi khong con",
        "trong state nao.",
        "Luu y bien moi truong DE LEN profile: dung",
        "`env -u AWS_PROFILE -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY",
        "-u AWS_SESSION_TOKEN terraform plan` de chac.",
      ])
    }
  }
}

# De RONG expected_account_id thi khong co gi chan ca. Noi ra mot lan,
# vi mot chot chan tat mac dinh la mot chot chan khong ai bat.
check "account_guard_is_armed" {
  assert {
    condition     = var.expected_account_id != ""
    error_message = "expected_account_id dang de rong - khong co gi chan viec chay layer nay bang credential cua account khac. Dat no bang: aws sts get-caller-identity --query Account --output text"
  }
}
