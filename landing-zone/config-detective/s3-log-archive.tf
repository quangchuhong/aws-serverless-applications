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

  # Moc chuyen storage class.
  #
  # 30 la TOI THIEU cua S3 cho STANDARD_IA - khong dat thap hon duoc.
  # Ca hai moc chi duoc dung khi expiration xa hon chung; xem dynamic
  # block trong aws_s3_bucket_lifecycle_configuration.
  ia_transition_days      = 30
  glacier_transition_days = 90

  # Account duoc phep giao file Config vao bucket nay.
  #
  # Lay TAT CA account ACTIVE chu khong chi cac account trong
  # recorder_target_ous: account nam ngoai pham vi khong co recorder
  # nen khong giao gi ca, con neu sau nay mo rong pham vi thi policy
  # da san sang - tranh mot lan sua policy nua.
  delivery_account_ids = sort([
    for a in data.aws_organizations_organization.this.accounts :
    a.id if a.status == "ACTIVE"
  ])
}

resource "aws_s3_bucket" "config" {
  count    = local.enabled ? 1 : 0
  provider = aws.log_archive

  bucket = local.bucket_name

  # CHI BAT DUOC LUC TAO BUCKET. Khong bat sau duoc.
  object_lock_enabled = var.enable_object_lock

  # Bucket bat versioning - khong co dong nay thi destroy dung lai
  # voi BucketNotEmpty du da "aws s3 rm --recursive".
  force_destroy = var.allow_destroy

  lifecycle {
    prevent_destroy = true

    ####################################
    # CHAN TRUOC KHI TAO, vi tao roi thi khong sua duoc
    #
    # AWS Config KHONG giao duoc file vao bucket bat Object Lock.
    # Da kiem chung: hai bucket giong het nhau tru Object Lock,
    # bucket khong khoa thi Config ghi duoc
    # AWSLogs/<account>/Config/ConfigWritabilityCheckFile ngay,
    # bucket khoa thi bao InsufficientDeliveryPolicyException.
    #
    # Cai gia cua viec khong chan o day rat cao: Object Lock chi bat
    # duoc LUC TAO BUCKET, nen apply xong la phai xoa bucket va lam
    # lai - trong khi prevent_destroy dang chan xoa.
    ####################################
    precondition {
      condition     = !var.enable_object_lock
      error_message = "enable_object_lock = true khong dung duoc: AWS Config khong ghi noi file kiem tra vao bucket co Object Lock, va bao InsufficientDeliveryPolicyException nghe nhu loi bucket policy. Muon bat bien khong xoa duoc thi phai them tang Config -> bucket thuong -> S3 Replication -> bucket khoa; xem mo ta bien enable_object_lock."
    }
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

    # Transition CHI xuat hien khi con kip truoc han xoa.
    #
    # Truoc day hai moc nay ghi cung 90 va 180 trong khi expiration
    # lay tu bien. Dat snapshot_retention_days = 30 la S3 tu choi ca
    # cau hinh:
    #   InvalidArgument: 'Days' in the Expiration action for filter
    #   '(prefix=)' must be greater than 'Days' in the Transition action
    #
    # 30 ngay la moc TOI THIEU cua S3 cho STANDARD_IA - dat nho hon
    # cung bi tu choi. Nen giu retention ngan thi don gian la khong
    # chuyen tang: object song qua ngan de viec chuyen tang co y nghia.
    dynamic "transition" {
      for_each = var.snapshot_retention_days > local.ia_transition_days ? [1] : []
      content {
        days          = local.ia_transition_days
        storage_class = "STANDARD_IA"
      }
    }

    dynamic "transition" {
      for_each = var.snapshot_retention_days > local.glacier_transition_days ? [1] : []
      content {
        days          = local.glacier_transition_days
        storage_class = "GLACIER_IR"
      }
    }

    # PHAI lon hon object_lock_retention_days, neu khong lifecycle
    # se co gang xoa object dang bi khoa va that bai lang le.
    expiration {
      days = var.snapshot_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = min(90, var.snapshot_retention_days)
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
      # DUNG AWS:SourceAccount, KHONG dung AWS:SourceOrgID.
      #
      # Config goi S3 voi tu cach DICH VU, mang theo SourceAccount la
      # account thanh vien dang giao file. SourceOrgID khong duoc dien
      # dang tin cho luoi goi nay - dieu kien khong bao giờ khop va
      # moi thu bi tu choi voi:
      #   InsufficientDeliveryPolicyException: unable to write to bucket
      #
      # Doi lai: them account moi thi PHAI apply lai layer nay, neu
      # khong account do khong giao duoc file. Gan buoc do vao account
      # vending (doc 09), giong nhu accounts_by_scope ben permission-sets.
      {
        Sid       = "AWSConfigBucketPermissionsCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.config[0].arn
        Condition = {
          StringEquals = { "AWS:SourceAccount" = local.delivery_account_ids }
        }
      },
      {
        Sid       = "AWSConfigBucketDelivery"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config[0].arn}/*"
        Condition = {
          StringEquals = { "AWS:SourceAccount" = local.delivery_account_ids }
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

########################################
# GOP HAI ACCOUNT - canh bao, khong chan
#
# Day la lua chon thiet ke hop le, khong phai loi. Nhung no lang le:
# apply xanh, moi thu chay, va lop bao ve da bien mat ma khong co
# dong nao noi ra.
########################################

check "evidence_lives_outside_the_operated_account" {
  assert {
    condition = (
      !local.enabled
      || var.log_archive_account_id == ""
      || var.log_archive_account_id != var.security_account_id
    )

    error_message = join(" ", [
      "log_archive_account_id trung security_account_id.",
      "Chay duoc, nhung bang chung gio nam trong account DUOC VAN HANH:",
      "lz-security-admin co iam:*, tuc co duong toi s3:DeleteObject qua",
      "mot role tu tao, va khong SCP nao hien tai chan viec do.",
      "Object Lock - thu duy nhat thay the duoc ranh gioi account -",
      "KHONG dung duoc voi AWS Config (loi 19 doc 22).",
      "Chap nhan thi bo qua canh bao nay; con khong thi tach account.",
    ])
  }
}
