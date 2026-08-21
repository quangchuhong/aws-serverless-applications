########################################
# S3 NHAN CONFIG SNAPSHOT - o account LOG ARCHIVE
#
# Tach rieng account nay co dung MOT muc dich:
#   account bi xam nhap KHONG XOA DUOC bang chung.
#
# Lifecycle policy khong lam duoc viec do - no chi chuyen storage
# class va het han. Thu lam duoc viec do la OBJECT LOCK.
########################################

data "aws_organizations_organization" "this" {}

locals {
  bucket_name = "${var.project}-config-snapshots-${var.log_archive_account_id}"
  org_id      = data.aws_organizations_organization.this.id
}

resource "aws_s3_bucket" "config" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = local.bucket_name

  # CHI BAT DUOC LUC TAO BUCKET. Khong bat sau duoc.
  object_lock_enabled = var.enable_object_lock

  lifecycle {
    prevent_destroy = true
  }
}

# Object Lock BAT BUOC versioning
resource "aws_s3_bucket_versioning" "config" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = aws_s3_bucket.config[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "config" {
  count    = local.enabled && var.enable_object_lock ? 1 : 0
  provider = aws.log_archive

  bucket = aws_s3_bucket.config[0].id

  rule {
    default_retention {
      # COMPLIANCE: khong ai go duoc, KE CA ROOT, cho toi het han.
      # GOVERNANCE: nguoi co quyen dac biet van go duoc.
      #
      # Bang chung kiem toan thi dung COMPLIANCE - nhung biet truoc:
      # object da ghi thi phai TRA TIEN LUU TRU du het han, khong
      # xoa som duoc bang bat ky cach nao.
      mode = "COMPLIANCE"
      days = var.object_lock_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.config]
}

resource "aws_s3_bucket_public_access_block" "config" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = aws_s3_bucket.config[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "config" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = aws_s3_bucket.config[0].id

  # Account chua bucket luon so huu moi object, ke ca object do
  # account khac ghi vao. Thieu dong nay thi log archive co the
  # khong doc duoc chinh file trong bucket cua minh.
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = aws_s3_bucket.config[0].id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 chu khong phai KMS: snapshot den tu RAT NHIEU account,
      # dung KMS thi phai cap quyen key cho tung account - them mot
      # cho de sai ma khong duoc gi nhieu, vi bucket da chan public
      # va da co Object Lock.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "config" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = aws_s3_bucket.config[0].id

  rule {
    id     = "tier-and-expire"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 180
      storage_class = "GLACIER_IR"
    }

    # PHAI lon hon object_lock_retention_days, neu khong lifecycle
    # se co gang xoa object dang bi khoa va that bai lang le.
    expiration {
      days = var.snapshot_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  # CHAN CUNG, khong phai canh bao.
  #
  # check "retention_longer_than_object_lock" o cuoi file cung kiem
  # dieu nay, nhung check chi CANH BAO - apply van chay. Voi loi nay
  # thi canh bao khong du: lifecycle se co xoa object dang bi Object
  # Lock giu, that bai LANG LE, object tich lai mai va ban tra tien
  # luu tru vo thoi han. Khong co thong bao nao.
  lifecycle {
    precondition {
      condition     = !var.enable_object_lock || var.snapshot_retention_days > var.object_lock_retention_days
      error_message = "snapshot_retention_days (${var.snapshot_retention_days}) phai LON HON object_lock_retention_days (${var.object_lock_retention_days}). Nho hon thi lifecycle co xoa object bi khoa, that bai lang le, object khong bao gio duoc don."
    }
  }

  depends_on = [aws_s3_bucket_versioning.config]
}

########################################
# Bucket policy
#
# LOI HAY GAP NHAT khi dung Config cross-account:
#   InsufficientDeliveryPolicyException
#
# Gan nhu luon la thieu mot trong hai statement duoi day, hoac
# thieu quyen tren KMS key neu bucket ma hoa bang KMS.
########################################

resource "aws_s3_bucket_policy" "config" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = aws_s3_bucket.config[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Config kiem tra quyen truoc khi giao - thieu statement nay
      # thi khong bao gio giao duoc file dau tien
      {
        Sid       = "AWSConfigBucketPermissionsCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.config[0].arn
        Condition = {
          StringEquals = { "AWS:SourceOrgID" = local.org_id }
        }
      },
      {
        Sid       = "AWSConfigBucketDelivery"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config[0].arn}/*"
        Condition = {
          StringEquals = { "AWS:SourceOrgID" = local.org_id }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.config[0].arn,
          "${aws_s3_bucket.config[0].arn}/*",
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.config]
}

########################################
# KIEM TRA CHEO
########################################

check "retention_longer_than_object_lock" {
  assert {
    condition     = !var.enable_object_lock || var.snapshot_retention_days > var.object_lock_retention_days
    error_message = "snapshot_retention_days phai LON HON object_lock_retention_days, neu khong lifecycle se co gang xoa object dang bi khoa va that bai lang le."
  }
}
