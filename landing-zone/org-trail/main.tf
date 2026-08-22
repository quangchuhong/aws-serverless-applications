########################################
# S3 - o ACCOUNT LOG ARCHIVE
########################################

locals {
  bucket_name = "${var.project}-cloudtrail-${var.log_archive_account_id}"
  org_id      = data.aws_organizations_organization.this.id
  trail_name  = "${var.project}-org-trail"

  # ARN cua trail, RAP TAY chu khong lay tu resource.
  #
  # VI SAO: bucket policy phai neu ten trail trong dieu kien
  # aws:SourceArn, ma trail lai can bucket policy dung truoc khi tao
  # duoc. Lay aws_cloudtrail.this[0].arn o day la vong lap.
  #
  # ARN cua trail hoan toan doan truoc duoc tu ba thu da biet, nen
  # rap tay la du va cat duoc vong lap.
  trail_arn = join("", [
    "arn:${data.aws_partition.current.partition}:cloudtrail:",
    var.region, ":",
    data.aws_caller_identity.current.account_id,
    ":trail/", local.trail_name,
  ])

  # Moc chuyen storage class. 30 la toi thieu cua S3 cho STANDARD_IA.
  ia_transition_days      = 30
  glacier_transition_days = 90
}

resource "aws_s3_bucket" "trail" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = local.bucket_name

  # CHI BAT DUOC LUC TAO BUCKET.
  object_lock_enabled = var.enable_object_lock

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "trail" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = aws_s3_bucket.trail[0].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_object_lock_configuration" "trail" {
  count    = local.enabled && var.enable_object_lock ? 1 : 0
  provider = aws.log_archive

  bucket = aws_s3_bucket.trail[0].id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.object_lock_retention_days
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = aws_s3_bucket.trail[0].id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 chu khong phai KMS. Log den tu MOI account trong to
      # chuc; dung KMS thi key policy phai cho tung account, va do
      # la mot cho de sai ma khong duoc gi nhieu - bucket da chan
      # public va nam o account rieng.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = aws_s3_bucket.trail[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "trail" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = aws_s3_bucket.trail[0].id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = aws_s3_bucket.trail[0].id

  rule {
    id     = "tier-and-expire"
    status = "Enabled"

    filter {}

    # Transition CHI xuat hien khi con kip truoc han xoa. S3 tu choi
    # ca cau hinh neu expiration som hon transition.
    dynamic "transition" {
      for_each = var.log_retention_days > local.ia_transition_days ? [1] : []
      content {
        days          = local.ia_transition_days
        storage_class = "STANDARD_IA"
      }
    }

    dynamic "transition" {
      for_each = var.log_retention_days > local.glacier_transition_days ? [1] : []
      content {
        days          = local.glacier_transition_days
        storage_class = "GLACIER_IR"
      }
    }

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = min(90, var.log_retention_days)
    }
  }

  lifecycle {
    precondition {
      condition     = !var.enable_object_lock || var.log_retention_days > var.object_lock_retention_days
      error_message = "log_retention_days (${var.log_retention_days}) phai LON HON object_lock_retention_days (${var.object_lock_retention_days}). Nho hon thi lifecycle co xoa object bi khoa, that bai lang le, va object khong bao gio duoc don."
    }
  }

  depends_on = [aws_s3_bucket_versioning.trail]
}

########################################
# BUCKET POLICY
#
# HAI STATEMENT, THIEU MOT LA HONG:
#
#   AWSCloudTrailAclCheck  - CloudTrail doc ACL de kiem quyen TRUOC
#                            khi giao file dau tien
#   AWSCloudTrailWrite     - quyen ghi that
#
# Va duong dan trong statement thu hai phai dung dang cua
# ORGANIZATION trail:
#
#   AWSLogs/<org-id>/<account-id>/CloudTrail/<region>/...
#            ^^^^^^^
#            trail thuong KHONG co doan nay
#
# Sai duong dan thi CloudTrail bao loi quyen ghi ma khong noi ro la
# do prefix.
########################################

resource "aws_s3_bucket_policy" "trail" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = aws_s3_bucket.trail[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.trail[0].arn
        Condition = {
          StringEquals = { "aws:SourceArn" = local.trail_arn }
        }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"

        # HAI DUONG DAN, khong phai mot.
        #
        # Organization trail ghi vao CA HAI:
        #   AWSLogs/<management-account-id>/CloudTrail/...   <- chinh management account
        #   AWSLogs/<org-id>/<account-id>/CloudTrail/...     <- account thanh vien
        #
        # Thieu duong dau thi CreateTrail tu choi ngay:
        #   InsufficientS3BucketPolicyException: Incorrect S3 bucket
        #   policy is detected for bucket: <ten>
        #
        # Thong bao KHONG noi thieu cho nao - chi noi "incorrect".
        Resource = [
          "${aws_s3_bucket.trail[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
          "${aws_s3_bucket.trail[0].arn}/AWSLogs/${local.org_id}/*",
        ]

        # KHONG dat dieu kien s3:x-amz-acl.
        #
        # Vi du trong tai lieu AWS co no, nhung do la cho bucket con
        # BAT ACL. Bucket nay dung BucketOwnerEnforced - chu bucket
        # LUON so huu object, bat ke ACL. Dieu kien do thanh thua, va
        # mot dieu kien thua chi them mot cho de truot.
        Condition = {
          StringEquals = { "aws:SourceArn" = local.trail_arn }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.trail[0].arn,
          "${aws_s3_bucket.trail[0].arn}/*",
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.trail]
}

########################################
# TRAIL - o MANAGEMENT ACCOUNT
#
# is_organization_trail chi dat duoc tu management account (hoac
# delegated administrator cua CloudTrail). Account con khong tat
# duoc trail nay - do la diem manh chinh so voi trail tung account.
########################################

resource "aws_cloudtrail" "this" {
  count = local.enabled ? 1 : 0

  name           = local.trail_name
  s3_bucket_name = aws_s3_bucket.trail[0].id

  # Phu moi account trong to chuc, ke ca account tao ve sau
  is_organization_trail = true

  # Su kien o MOI region, khong chi region dat trail. Bo cai nay la
  # tu tao mot vung mu dung bang so region con lai.
  is_multi_region_trail = true

  enable_log_file_validation = var.enable_log_file_validation
  enable_logging             = true

  # Data event TINH TIEN THEO SU KIEN. Xem mo ta var.data_events.
  dynamic "event_selector" {
    for_each = var.data_events ? [1] : []
    content {
      read_write_type           = "All"
      include_management_events = true

      data_resource {
        type   = "AWS::S3::Object"
        values = ["arn:${data.aws_partition.current.partition}:s3"]
      }
    }
  }

  # Bucket policy phai ton tai TRUOC khi tao trail - CloudTrail kiem
  # quyen ghi ngay luc tao va tu choi neu chua co.
  depends_on = [aws_s3_bucket_policy.trail]
}

########################################
# KIEM TRA CHEO
########################################

check "log_archive_is_not_management" {
  assert {
    condition     = !local.enabled || var.log_archive_account_id != data.aws_caller_identity.current.account_id
    error_message = "log_archive_account_id trung management account. Ca ly do tach account nay la de account bi xam nhap khong xoa duoc bang chung cua chinh no - dat bucket ngay trong do la mat y nghia."
  }
}

check "cloudtrail_service_access_enabled" {
  assert {
    condition = !local.enabled || contains(
      data.aws_organizations_organization.this.aws_service_access_principals,
      "cloudtrail.amazonaws.com",
    )

    error_message = join(" ", [
      "Chua bat service access cho cloudtrail.amazonaws.com o pham vi to chuc.",
      "is_organization_trail se bi tu choi.",
      "Them vao aws_service_access_principals ben landing-zone/organization roi apply lai.",
    ])
  }
}

check "data_events_cost_warning" {
  assert {
    condition     = !var.data_events
    error_message = "data_events = true: CloudTrail tinh tien theo TUNG su kien data, va o pham vi to chuc thi mot bucket S3 binh thuong sinh hang trieu su kien moi thang. Chi bat khi da khoanh pham vi cu the trong event_selector."
  }
}
