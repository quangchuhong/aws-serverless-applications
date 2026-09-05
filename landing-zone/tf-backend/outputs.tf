locals {
  ########################################
  # Cac layer dung chung bucket nay.
  #
  # Moi layer mot key rieng -> state TACH BIET. Apply layer network
  # khong the lam hong state cua layer permission-sets.
  #
  # Them layer moi thi them mot dong o day.
  ########################################
  layers = {
    "landing-zone/tf-backend"       = "bootstrap/terraform.tfstate"
    "landing-zone/organization"     = "organization/terraform.tfstate"
    "landing-zone/config-detective" = "config-detective/terraform.tfstate"
    "landing-zone/billing-guard"    = "billing-guard/terraform.tfstate"
    "landing-zone/permission-sets"  = "permission-sets/terraform.tfstate"
    "landing-zone/org-trail"        = "org-trail/terraform.tfstate"
    "landing-zone/account-baseline" = "account-baseline/terraform.tfstate"
    "landing-zone/service-catalog"  = "service-catalog/terraform.tfstate"

    # "landing-zone/network" KHONG khai o day - xem khoi ben duoi.
    #
    # Truoc day no duoc khai o CA HAI cho, "network/terraform.tfstate"
    # o dong nay va "demo-network-lz-full/..." o duoi. HCL khong bao
    # khoa trung trong mot object literal: cai SAU de len cai truoc, im
    # lang. Nen dong o day chua bao gio co tac dung - va ai xoa khoi
    # ben duoi di se lang le tro layer network vao mot state RONG.

    # Demo, NHUNG dang duoc giu lai lam mang that (ephemeral = false).
    # Demo binh thuong dung state local la du - dung len xem roi xoa.
    # Cai nay thi khong: state cua ha tang thuong tru ma nam tren mot
    # cai laptop la mat may = mat quyen quan ly mang cua ca to chuc.
    #
    # Doi ephemeral ve true (dung-xem-xoa) thi bo dong nay di.
    # KHOA KHONG KHOP DUONG DAN - CO CHU DICH.
    #
    # Layer nay truoc o demo/network-lz-full va da APPLY THAT. Khi no
    # thay the landing-zone/network, duong dan doi nhung khoa state
    # GIU NGUYEN.
    #
    # Doi khoa nghia la Terraform mo mot state RONG o duong dan moi:
    # plan doi tao lai ca ~200 resource, va ha tang that thanh mo coi
    # - van chay, van tinh tien, khong con ai quan. Con te hon:
    # ./teardown.sh chay tren state rong se khong xoa gi va bao "da
    # sach".
    #
    # Doi duoc khoa khi state RONG (sau mot lan destroy). Luc do:
    #   aws s3 rm s3://<bucket>/demo-network-lz-full/terraform.tfstate
    #   <XOA CA DONG DIGEST - xem duoi>
    #   sua dong nay, chay ./wire-backends.sh, terraform init -reconfigure
    #
    # XOA OBJECT S3 THOI LA CHUA DU khi lock_mode = "dynamodb".
    #
    # Bang khoa giu them mot dong DIGEST cho moi key:
    #   LockID = "<bucket>/<key>-md5"
    # Dong do KHONG bien mat khi object bi xoa. Lan init sau, Terraform
    # so md5 cua object (rong, hoac moi) voi digest cu va dung lai:
    #
    #   Error: state data in S3 does not have the expected content.
    #   Calculated checksum:            <- rong, vi object rong
    #   Stored checksum:     c92a3ed1...
    #
    # Cau do doc nhu mot su co cua AWS ("unusually long delays in S3")
    # va bao nguoi ta cho vai phut. Cho bao lau cung khong het.
    #
    #   TABLE=$(terraform output -raw lock_table)
    #   aws dynamodb delete-item --region <region> --table-name "$TABLE" \
    #     --key '{"LockID":{"S":"<bucket>/<key>-md5"}}'
    "landing-zone/network" = "demo-network-lz-full/terraform.tfstate"

    # Lop van hanh cua layer tren - state RIENG, cung PREFIX.
    #
    # Cung prefix la bat buoc, khong phai cho gon: bucket policy cap
    # quyen theo prefix (var.state_writer_accounts), va bucket nay
    # cap cho layer tren qua profile (var.backend_profiles). Dat key
    # ra mot prefix moi - "network-ops/" chang han - la khong co dong
    # Allow nao phu, va terraform init bao 403 ma khong nhac gi toi
    # prefix.
    #
    # State rieng vi hai lop doi voi nhip khac han nhau: layer tren
    # doi vai thang mot lan, lop nay doi hang ngay. Xem
    # landing-zone/network/ops/versions.tf.
    "landing-zone/network/ops" = "demo-network-lz-full/ops/terraform.tfstate"

    # Ban Control Tower - mac dinh TAT, nhung van can key rieng neu
    # ban bat no. KHONG dung chung key voi organization: hai layer do
    # thay the nhau, dung chung state se giam len nhau.
    "landing-zone/control-tower" = "control-tower/terraform.tfstate"

  }

  # Dong khoa trong backend config, khac nhau theo lock_mode
  lock_line = (
    var.lock_mode == "dynamodb"
    ? "dynamodb_table = \"${try(aws_dynamodb_table.lock[0].name, "")}\""
    : "use_lockfile   = true   # CAN Terraform >= 1.10"
  )

  backend_configs = {
    for dir, key in local.layers : dir => join("\n", compact([
      "bucket         = \"${aws_s3_bucket.state.id}\"",
      "key            = \"${key}\"",
      "region         = \"${var.region}\"",
      "encrypt        = true",
      var.use_kms_cmk ? "kms_key_id     = \"${local.kms_arn}\"" : "",

      # Chi layer nao co BACKEND va RESOURCE o hai account khac nhau
      # moi can dong nay. Xem var.backend_profiles.
      try(var.backend_profiles[dir], "") != ""
      ? "profile        = \"${var.backend_profiles[dir]}\""
      : "",

      local.lock_line,
    ]))
  }
}

########################################
# Khoa cua backend_profiles phai la mot layer co that.
#
# backend_configs tra cuu bang try(var.backend_profiles[dir], "") -
# tra cuu theo dir, nen mot khoa KHONG khop layer nao chi don gian
# khong bao gio duoc doc. Khong loi, khong canh bao, va backend.hcl
# sinh ra thieu dong profile y het nhu khi quen khai han.
#
# Da xay ra that: terraform.tfvars.example de san
# "demo/network-lz-full/ops" tu truoc khi lop do chuyen sang
# landing-zone/network/ops. Ai chep dong do ra se khai mot profile
# khong bao gio co tac dung.
########################################
check "backend_profiles_tro_dung_layer" {
  assert {
    condition = length(setsubtract(keys(var.backend_profiles), keys(local.layers))) == 0
    error_message = join(" ", [
      "backend_profiles co khoa khong khop layer nao:",
      join(", ", setsubtract(keys(var.backend_profiles), keys(local.layers))),
      "- chung se bi BO QUA lang le.",
      "Khoa hop le:", join(", ", sort(keys(local.layers))),
    ])
  }
}

output "bucket" {
  description = "Ten bucket chua state"
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "Bang DynamoDB dung de khoa (rong neu lock_mode = s3)"
  value       = try(aws_dynamodb_table.lock[0].name, "")
}

output "kms_key_arn" {
  description = "ARN cua KMS key (rong neu dung SSE-S3)"
  value       = var.use_kms_cmk ? local.kms_arn : ""
}

output "layers" {
  description = "Layer -> key trong bucket"
  value       = local.layers
}

output "backend_hcl" {
  description = <<-EOT
    Noi dung file backend.hcl cho tung layer.

    Khong phai copy tay - chay ./wire-backends.sh de ghi tu dong.
  EOT
  value       = local.backend_configs
}

output "next_steps" {
  value = <<-EOT

    BUOC 3 - CHUYEN CHINH LAYER NAY SANG REMOTE STATE

      Hien tai state cua tf-backend van nam tren may ban. Chuyen no
      vao bucket vua tao:

        1. Bo comment dong backend "s3" {} trong versions.tf
        2. ./wire-backends.sh
        3. terraform init -migrate-state -backend-config=backend.hcl
           -> Terraform hoi "copy existing state?" -> yes
        4. Kiem tra: terraform state list  (phai con nguyen resource)
        5. Xoa terraform.tfstate va terraform.tfstate.backup o local

      Bo qua buoc nay = mat may la mat quyen quan ly bucket state
      cua ca to chuc.

    BUOC 4 - NOI CAC LAYER KHAC

      ./wire-backends.sh   ghi backend.hcl cho moi layer trong
                           output "layers"

      Voi tung layer:
        cd <layer> && terraform init -migrate-state -backend-config=backend.hcl

    BUOC 5 - THU CONG, KHONG LAM BANG TERRAFORM DUOC

      Bat MFA Delete cho bucket state. Chi lam duoc bang credential
      ROOT cua account nay, va bat buoc qua CLI:

        aws s3api put-bucket-versioning \
          --bucket ${aws_s3_bucket.state.id} \
          --versioning-configuration Status=Enabled,MFADelete=Enabled \
          --mfa "arn:aws:iam::${local.account_id}:mfa/root-account-mfa-device <ma-6-so>"

      Sau khi bat, xoa version state phai co MFA. Day la lop chan
      cuoi cung chong xoa nham.

  EOT
}
