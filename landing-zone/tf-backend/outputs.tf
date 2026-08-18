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

    # Ban Control Tower - mac dinh TAT, nhung van can key rieng neu
    # ban bat no. KHONG dung chung key voi organization: hai layer do
    # thay the nhau, dung chung state se giam len nhau.
    "landing-zone/control-tower" = "control-tower/terraform.tfstate"

    # Chua co code - them khi dung toi
    # "landing-zone/network" = "network/terraform.tfstate"
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
      local.lock_line,
    ]))
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
