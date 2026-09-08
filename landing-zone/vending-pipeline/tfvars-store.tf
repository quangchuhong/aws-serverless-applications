########################################
# KHO terraform.tfvars CHO PIPELINE
#
# ---------------------------------------------------------------
# VAN DE
#
# .gitignore loai `terraform.tfvars` khoi repo, co y: no chua account
# ID, email, ma phong ban. Nen ban checkout cua CodeBuild KHONG CO
# tfvars cua layer nao.
#
# Va day KHONG phai mot loi to ra ngay. Ba trong bon layer khong co
# bien bat buoc nao - moi bien deu co `default`:
#
#   account-baseline   khong co bien bat buoc
#   network            khong co bien bat buoc
#   config-detective   khong co bien bat buoc
#   permission-sets    management_account_id
#
# Thieu tfvars thi `terraform plan` chay THANH CONG voi catalog = {},
# spokes = {}, ou_ids = {} - tren DUNG state that. Nghia la plan mo ta
# viec XOA account, StackSet, VPC, attachment dang co.
#
# Chot chan state rong trong buildspec khong bat duoc: state day du,
# chi co bien la rong.
#
# ---------------------------------------------------------------
# CACH XU LY
#
# Mot bucket rieng, ngoai git, buildspec keo ve truoc `init`. THIEU
# FILE LA LOI CUNG - khong bao gio de plan chay voi gia tri mac dinh.
#
# Khong dung SSM Parameter Store: parameter Standard gioi han 4 KB va
# tfvars cua account-baseline (co ca catalog) vuot qua duoc. Mot gioi
# han cham toi luc file dai them mot account la mot gioi han se cham
# toi vao dung luc te nhat.
#
# Khong dung chung bucket artifact: bucket do co lifecycle xoa sau 30
# ngay. tfvars nam trong do se bien mat trong im lang, va lan chay sau
# do se la lan plan doi xoa moi thu.
#
# Day file len:  ./push-tfvars.sh
########################################

resource "aws_s3_bucket" "tfvars" {
  count = local.enabled ? 1 : 0

  bucket = "${local.name}-tfvars-${data.aws_caller_identity.current.account_id}"

  # Xoa bucket nay = pipeline mat cau hinh cua ca bon layer.
  force_destroy = false

  tags = { Name = "${local.name}-tfvars" }
}

resource "aws_s3_bucket_public_access_block" "tfvars" {
  count = local.enabled ? 1 : 0

  bucket                  = aws_s3_bucket.tfvars[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfvars" {
  count = local.enabled ? 1 : 0

  bucket = aws_s3_bucket.tfvars[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.artifacts[0].arn
    }
    bucket_key_enabled = true
  }
}

# Versioning la bat buoc o day, khong phai cho du.
#
# Day nham mot ban tfvars thieu mot account len bucket nay se khien
# lan chay sau plan ra "xoa account do". Co version thi lui lai duoc
# bang mot lenh; khong co thi phai dung lai file tu tri nho.
resource "aws_s3_bucket_versioning" "tfvars" {
  count = local.enabled ? 1 : 0

  bucket = aws_s3_bucket.tfvars[0].id
  versioning_configuration { status = "Enabled" }
}

# CO Y KHONG CO expiration cho ban HIEN HANH.
#
# Chi don ban cu, va giu 90 ngay - du de lui lai sau khi phat hien
# mot lan day nham.
resource "aws_s3_bucket_lifecycle_configuration" "tfvars" {
  count = local.enabled ? 1 : 0

  bucket = aws_s3_bucket.tfvars[0].id

  rule {
    id     = "don-ban-cu"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration { noncurrent_days = 90 }

    abort_incomplete_multipart_upload { days_after_initiation = 3 }
  }
}

resource "aws_s3_bucket_policy" "tfvars" {
  count = local.enabled ? 1 : 0

  bucket = aws_s3_bucket.tfvars[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ChiTLS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.tfvars[0].arn,
        "${aws_s3_bucket.tfvars[0].arn}/*",
      ]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# Cho ./push-tfvars.sh doc, de script khong phai doan vung.
output "region" {
  value = var.region
}

output "tfvars_bucket" {
  description = <<-EOT
    Bucket chua terraform.tfvars cua bon layer.

    Day file len bang ./push-tfvars.sh. Khoa co dang:

      tfvars/<duong-dan-layer>/terraform.tfvars

    vi du tfvars/landing-zone/account-baseline/terraform.tfvars
  EOT
  value       = local.enabled ? aws_s3_bucket.tfvars[0].bucket : ""
}
