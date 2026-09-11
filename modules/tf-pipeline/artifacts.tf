########################################
# KHO ARTIFACT CUA PIPELINE
#
# Rieng, khong dung chung voi vending-pipeline. Ly do khong phai ky
# thuat ma la pham vi: artifact chua BAN PLAN da luu, va mot ban plan
# la mot mo ta chinh xac nhung gi sap doi o ha tang. Hai pipeline co
# ban kinh thiet hai khac han nhau thi khong nen doc/ghi cung mot cho.
#
# Kho tfvars thi NGUOC LAI - dung chung, xem variables.tf. Khac biet:
# tfvars la DAU VAO do nguoi day len, va hai kho dau vao la hai cho
# phai day, tuc mot cho cu la mot ban plan sai khong co loi nao.
########################################

resource "aws_kms_key" "artifacts" {
  count = local.enabled ? 1 : 0

  description             = "${local.name} artifact"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "artifacts" {
  count = local.enabled ? 1 : 0

  name          = "alias/${local.name}-artifacts"
  target_key_id = aws_kms_key.artifacts[0].key_id
}

resource "aws_s3_bucket" "artifacts" {
  count = local.enabled ? 1 : 0

  bucket        = "${local.name}-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
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

# Artifact khong can giu lau - chung la ban sao cua mot commit va mot
# ban plan da thuc hien. Giu 30 ngay de con doc lai duoc khi dieu tra.
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  count = local.enabled ? 1 : 0

  bucket = aws_s3_bucket.artifacts[0].id

  rule {
    id     = "het-han"
    status = "Enabled"
    filter {}

    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 7 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

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
