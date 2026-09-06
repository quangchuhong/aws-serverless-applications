########################################
# ARTIFACT GIUA CAC STAGE
#
# CodePipeline chuyen thu muc lam viec tu stage plan sang stage apply
# qua bucket nay. Trong do co file `tfplan`.
#
# ---------------------------------------------------------------
# tfplan LA MOT TAI LIEU NHAY CAM
#
# No khong chua credential, nhung no chua TOAN BO gia tri ma plan
# tinh ra - ke ca thuoc tinh danh dau `sensitive` trong code, vi
# `sensitive` chi anh huong toi cach IN RA man hinh, khong anh huong
# toi thu duoc ghi vao file plan.
#
# Voi cac layer o day: email cua account moi, ID cua moi resource
# mang, va noi dung day du cua moi SCP. Nen bucket nay ma hoa bang
# KMS, chan truy cap cong khai, va tu don sau 30 ngay.
########################################

resource "aws_kms_key" "artifacts" {
  count = local.enabled ? 1 : 0

  description             = "${local.name}: ma hoa artifact cua pipeline"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = { Name = "${local.name}-artifacts" }
}

resource "aws_kms_alias" "artifacts" {
  count = local.enabled ? 1 : 0

  name          = "alias/${local.name}-artifacts"
  target_key_id = aws_kms_key.artifacts[0].key_id
}

resource "aws_s3_bucket" "artifacts" {
  count = local.enabled ? 1 : 0

  bucket = "${local.name}-artifacts-${data.aws_caller_identity.current.account_id}"

  # force_destroy = false: bucket nay giu tfplan cua moi lan chay, va
  # xoa nham chung nghia la mat dau vet cua nhung gi da duoc duyet.
  force_destroy = false

  tags = { Name = "${local.name}-artifacts" }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  count = local.enabled ? 1 : 0

  bucket                  = aws_s3_bucket.artifacts[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  count = local.enabled ? 1 : 0

  bucket = aws_s3_bucket.artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.artifacts[0].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  count = local.enabled ? 1 : 0

  bucket = aws_s3_bucket.artifacts[0].id
  versioning_configuration { status = "Enabled" }
}

# Don rac. Khong co khoi nay thi bucket phinh mai: moi lan chay de
# lai mot ban sao day du cua bon thu muc layer, ke ca .terraform voi
# provider binary vai tram MB.
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  count = local.enabled ? 1 : 0

  bucket = aws_s3_bucket.artifacts[0].id

  rule {
    id     = "don-artifact-cu"
    status = "Enabled"
    filter {}

    expiration { days = 30 }

    noncurrent_version_expiration { noncurrent_days = 7 }

    abort_incomplete_multipart_upload { days_after_initiation = 3 }
  }
}

# Chi cho phep goi qua TLS. Mot dong, va no dong dung cai lo hong ma
# ai cung quen cho toi khi co bao cao pentest.
resource "aws_s3_bucket_policy" "artifacts" {
  count = local.enabled ? 1 : 0

  bucket = aws_s3_bucket.artifacts[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ChiTLS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.artifacts[0].arn,
        "${aws_s3_bucket.artifacts[0].arn}/*",
      ]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}
