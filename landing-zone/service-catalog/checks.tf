########################################
# KIEM TRA CHEO
#
# Layer nay co nhieu cach "chay tron nhung khong lam gi" hon binh
# thuong, vi gia tri cua no nam o mot dieu Terraform khong thay duoc:
# nguoi dung co con quyen tao thang hay khong.
########################################

check "catalog_not_in_management" {
  assert {
    condition = (
      !local.enabled
      || var.management_account_id == ""
      || data.aws_caller_identity.current.account_id != var.management_account_id
    )

    error_message = join(" ", [
      "Catalog dang dung o MANAGEMENT account.",
      "Chay duoc, nhung management account nen sach: khong workload,",
      "rat it nguoi vao, va SCP khong ap len no nen moi quyen cap o day",
      "la quyen that khong co tran chan - trong khi catalog tu phuc vu",
      "la thu nguoi ta vao thuong xuyen.",
      "To chuc lon len thi tach mot account shared-services lam hub va",
      "chay layer nay bang credential cua account do.",
    ])
  }
}

check "tag_options_force_a_choice" {
  assert {
    condition = !local.enabled || length(local.keys_forcing_choice) > 0
    error_message = join(" ", [
      "Khong key nao co tu 2 gia tri tro len, nen khong ai bi BUOC CHON gi ca.",
      "Tag van duoc gan tu dong, nhung do la thu default_tags da lam roi",
      "va lam tot hon. Gia tri rieng cua TagOption den tu viec ep nguoi",
      "dung chon - vi du CostCenter voi danh sach ma phong ban that.",
    ])
  }
}

check "shared_somewhere" {
  assert {
    condition = !local.enabled || length(var.share_ou_arns) > 0
    error_message = join(" ", [
      "share_ou_arns rong: portfolio chi dung duoc trong chinh account hub.",
      "Doi ung dung o account khac se khong thay gi.",
      "Khai ARN cua OU (khong phai ID) de chia sang cho ho.",
    ])
  }
}

check "launch_role_has_permissions" {
  assert {
    condition = (
      !local.enabled
      || !var.create_launch_role
      || length(var.launch_role_policy_arns) > 0
    )
    error_message = join(" ", [
      "Launch role duoc tao nhung KHONG gan policy nao.",
      "Role khong lam duoc gi thi moi lan launch product deu that bai",
      "o buoc CloudFormation - va loi bao ve la loi quyen cua role,",
      "khong nhac gi toi Service Catalog.",
      "Gan policy du cho nhung product ban dua vao catalog. Dung gan",
      "AdministratorAccess: ai launch duoc product se gian tiep co quyen do.",
    ])
  }
}

check "tag_options_match_tag_policy" {
  assert {
    condition = (
      !local.enabled
      || !contains(keys(var.tag_options), "Environment")
      || length(setsubtract(
        toset(var.tag_options["Environment"]),
        toset(["dev", "staging", "prod", "sandbox"]),
      )) == 0
    )

    error_message = join(" ", [
      "tag_options[\"Environment\"] co gia tri ngoai chuan doc 11:",
      join(", ", tolist(setsubtract(
        toset(try(var.tag_options["Environment"], [])),
        toset(["dev", "staging", "prod", "sandbox"]),
      ))),
      "- nguoi dung se chon duoc mot gia tri ma tag policy ben layer",
      "organization danh dau la khong tuan thu. Hai cho phai khop nhau.",
    ])
  }
}
