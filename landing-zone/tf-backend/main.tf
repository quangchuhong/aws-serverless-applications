locals {
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  bucket_name = "${var.prefix}-tfstate-${local.account_id}"
  log_bucket  = "${var.prefix}-tfstate-logs-${local.account_id}"

  create_dynamodb = contains(["dynamodb", "both"], var.lock_mode)
  kms_arn         = var.use_kms_cmk ? aws_kms_key.state[0].arn : null
}

########################################
# 1. KMS key (tuy chon)
########################################

resource "aws_kms_key" "state" {
  count = var.use_kms_cmk ? 1 : 0

  description = "Ma hoa Terraform state cua Landing Zone"

  # Xoa nham key = state khong con doc duoc, VINH VIEN.
  # 30 ngay la cua so toi da de doi y.
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid       = "EnableRootPermissions"
          Effect    = "Allow"
          Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
          Action    = "kms:*"
          Resource  = "*"
        }
      ],
      # Account con ghi state cross-account thi phai dung duoc key
      length(var.state_writer_accounts) > 0 ? [
        {
          Sid    = "AllowStateWriterAccounts"
          Effect = "Allow"
          Principal = {
            AWS = [
              for _, id in var.state_writer_accounts :
              "arn:${local.partition}:iam::${id}:root"
            ]
          }
          Action = [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:DescribeKey",
          ]
          Resource = "*"
        }
      ] : [],
    )
  })
}

resource "aws_kms_alias" "state" {
  count = var.use_kms_cmk ? 1 : 0

  name          = "alias/${var.prefix}-tfstate"
  target_key_id = aws_kms_key.state[0].key_id
}

########################################
# 2. Bucket log truy cap
########################################

resource "aws_s3_bucket" "logs" {
  count  = var.enable_access_logging ? 1 : 0
  bucket = local.log_bucket
}

resource "aws_s3_bucket_public_access_block" "logs" {
  count  = var.enable_access_logging ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  count  = var.enable_access_logging ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      # Bucket dich cua S3 access log KHONG dung duoc SSE-KMS.
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  count  = var.enable_access_logging ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }
  }
}

# S3 logging service ghi bang principal logging.s3.amazonaws.com
resource "aws_s3_bucket_policy" "logs" {
  count  = var.enable_access_logging ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3ServerAccessLogging"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.logs[0].arn}/*"
        Condition = {
          ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:s3:::${local.bucket_name}" }
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.logs[0].arn,
          "${aws_s3_bucket.logs[0].arn}/*",
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

########################################
# 3. Bucket state
########################################

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # KHONG BO DONG NAY.
  #
  # Xoa bucket state = moi layer khac mat dau vet ve resource cua
  # minh. Terraform se khong con biet cai gi la cua no, va ban phai
  # import lai tung resource bang tay.
  #
  # Muon xoa that thi bo lifecycle nay, apply, roi moi destroy -
  # hai buoc co chu dich, khong the lo tay.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning la thu CUU BAN khi apply nham. Bat truoc moi thu khac.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.use_kms_cmk ? "aws:kms" : "AES256"
      kms_master_key_id = local.kms_arn
    }

    # Giam so lan goi KMS -> giam chi phi va do tre
    bucket_key_enabled = var.use_kms_cmk
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# BucketOwnerEnforced: tat ACL, va account chua bucket LUON so huu
# moi object - ke ca object do account khac ghi vao.
#
# Khong co dong nay thi state do account network ghi len se thuoc so
# huu cua account network, va management account co the KHONG DOC
# DUOC chinh file trong bucket cua minh.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

resource "aws_s3_bucket_logging" "state" {
  count = var.enable_access_logging ? 1 : 0

  bucket        = aws_s3_bucket.state.id
  target_bucket = aws_s3_bucket.logs[0].id
  target_prefix = "s3-access/"
}

########################################
# 4. Bucket policy
########################################

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        # Chan moi truy cap khong qua TLS
        {
          Sid       = "DenyInsecureTransport"
          Effect    = "Deny"
          Principal = "*"
          Action    = "s3:*"
          Resource = [
            aws_s3_bucket.state.arn,
            "${aws_s3_bucket.state.arn}/*",
          ]
          Condition = { Bool = { "aws:SecureTransport" = "false" } }
        },
      ],

      # Moi account con chi ghi duoc vao prefix cua chinh no.
      # Account network khong doc duoc state cua account security.
      flatten([
        for name, id in var.state_writer_accounts : [
          {
            Sid       = "ListBucketFor${replace(title(name), "-", "")}"
            Effect    = "Allow"
            Principal = { AWS = "arn:${local.partition}:iam::${id}:root" }
            Action    = "s3:ListBucket"
            Resource  = aws_s3_bucket.state.arn
            Condition = {
              StringLike = { "s3:prefix" = ["${name}/*"] }
            }
          },
          {
            Sid       = "ObjectAccessFor${replace(title(name), "-", "")}"
            Effect    = "Allow"
            Principal = { AWS = "arn:${local.partition}:iam::${id}:root" }
            Action = [
              "s3:GetObject",
              "s3:PutObject",
              "s3:DeleteObject",
            ]
            Resource = "${aws_s3_bucket.state.arn}/${name}/*"
          },
        ]
      ]),
    )
  })

  depends_on = [aws_s3_bucket_public_access_block.state]
}

########################################
# 5. Bang khoa DynamoDB
#
# Chi tao khi lock_mode = dynamodb | both.
#
# Terraform >= 1.10 khoa duoc bang chinh S3 (use_lockfile = true),
# khi do khong can bang nay nua.
########################################

resource "aws_dynamodb_table" "lock" {
  count = local.create_dynamodb ? 1 : 0

  name = "${var.prefix}-tfstate-lock"

  # Khoa state la vai request moi lan apply - PAY_PER_REQUEST re hon
  # provisioned rat nhieu, thuc te ~$0.
  billing_mode = "PAY_PER_REQUEST"

  # Ten thuoc tinh PHAI dung la LockID - Terraform hardcode ten nay.
  hash_key = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = var.use_kms_cmk
    kms_key_arn = local.kms_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_dynamodb_resource_policy" "lock" {
  count = local.create_dynamodb && length(var.state_writer_accounts) > 0 ? 1 : 0

  resource_arn = aws_dynamodb_table.lock[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowStateWriterAccountsToLock"
        Effect = "Allow"
        Principal = {
          AWS = [
            for _, id in var.state_writer_accounts :
            "arn:${local.partition}:iam::${id}:root"
          ]
        }
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
        ]
        Resource = aws_dynamodb_table.lock[0].arn
      }
    ]
  })
}
