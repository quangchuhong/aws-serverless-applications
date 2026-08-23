########################################
# AWS NETWORK FIREWALL
#
# KHOAN DAT NHAT CUA CA LANDING ZONE: ~$0.395/gio moi endpoint,
# tuc ~285 USD/thang moi AZ. Chay 24/7 du co goi tin nao di qua hay
# khong, va khong co che do "tam dung".
#
# Mot endpoint moi AZ - bat buoc, khong phai lua chon: subnet o AZ-a
# khong tro duoc vao endpoint nam o AZ-b.
########################################

resource "aws_networkfirewall_firewall" "main" {
  count    = local.fw
  provider = aws.network

  name                = "${var.project}-fw"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.main[0].arn
  vpc_id              = aws_vpc.security[0].id

  # KHAC BAN DEMO: o day bat bao ve that.
  #
  # delete_protection ngan xoa nham ca firewall - va xoa firewall
  # thi moi route tro vao endpoint cua no thanh mo coi, toan bo LZ
  # mat ket noi. Muon xoa that thi doi thanh false rieng mot lan
  # apply, roi moi destroy.
  delete_protection                 = true
  subnet_change_protection          = true
  firewall_policy_change_protection = false

  dynamic "subnet_mapping" {
    for_each = local.azs
    content {
      subnet_id = aws_subnet.security_firewall[subnet_mapping.key].id
    }
  }

  tags = { Name = "${var.project}-fw" }
}

########################################
# Endpoint ID theo TUNG AZ
#
# sync_states la mot set, khong phai list co thu tu - nen KHONG
# duoc lay theo chi so. Phai lap thanh map AZ -> endpoint id, roi
# route cua moi AZ tra cuu dung endpoint cua chinh no.
#
# Lay nham endpoint khac AZ thi luong di cheo AZ va firewall
# stateful chi thay nua phien.
########################################

locals {
  fw_endpoints = local.fw == 1 ? {
    for s in tolist(aws_networkfirewall_firewall.main[0].firewall_status[0].sync_states) :
    s.availability_zone => tolist(s.attachment)[0].endpoint_id
  } : {}
}

########################################
# Policy
########################################

locals {
  # alert = chi ghi log, KHONG chan.
  # drop  = chan that.
  stateful_default = (
    var.firewall_mode == "drop"
    ? ["aws:drop_established", "aws:alert_established"]
    : ["aws:alert_established"]
  )
}

resource "aws_networkfirewall_firewall_policy" "main" {
  count    = local.fw
  provider = aws.network

  name = "${var.project}-policy"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    # STRICT_ORDER de priority co y nghia. Mac dinh
    # (DEFAULT_ACTION_ORDER) danh gia theo do uu tien cua hanh dong
    # chu khong theo thu tu ban viet - rat de nham.
    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }

    stateful_default_actions = local.stateful_default

    stateful_rule_group_reference {
      priority     = 100
      resource_arn = aws_networkfirewall_rule_group.east_west[0].arn
    }

    stateful_rule_group_reference {
      priority     = 200
      resource_arn = aws_networkfirewall_rule_group.egress_domains[0].arn
    }
  }
}

########################################
# EAST-WEST: spoke nao duoc goi spoke nao
#
# DAY LA CHO DUY NHAT can sua khi muon mo/dong ket noi VPC-to-VPC.
# rtb-spokes van chi co dung mot dong 0.0.0.0/0 -> security.
########################################

resource "aws_networkfirewall_rule_group" "east_west" {
  count    = local.fw
  provider = aws.network

  capacity = 200
  name     = "${var.project}-east-west"
  type     = "STATEFUL"

  rule_group {
    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }

    rules_source {
      rules_string = join("\n", concat(
        [
          for i, r in var.east_west_rules :
          format(
            "pass tcp %s any -> %s %d (msg:\"ALLOW %s\"; sid:%d; rev:1;)",
            r.from_cidr, r.to_cidr, r.port, r.note, 1000 + i
          )
        ],

        [
          # ICMP noi bo - de con troubleshoot duoc. Khong co dong nay
          # thi o che do drop, ping tat va nguoi ta se tuong mang hong
          # trong khi TCP van chay.
          "pass icmp ${var.internal_supernet} any -> ${var.internal_supernet} any (msg:\"internal icmp\"; sid:1900; rev:1;)",

          # Ghi log MOI luong noi bo khong khop rule nao o tren.
          #
          # Doc alert log cua rule nay trong mot tuan = ban do that ve
          # ai dang goi ai. Do la thu dung de viet east_west_rules,
          # thay vi doan roi bat drop va cho dien thoai reo.
          "alert ip ${var.internal_supernet} any -> ${var.internal_supernet} any (msg:\"UNMATCHED east-west\"; sid:1999; rev:1;)",
        ]
      ))
    }
  }
}

########################################
# EGRESS: allowlist domain theo TLS SNI / HTTP Host
#
# Chi co tac dung khi firewall_mode = "drop". O che do "alert" thi
# moi thu van di qua - danh sach nay chi de san.
########################################

resource "aws_networkfirewall_rule_group" "egress_domains" {
  count    = local.fw
  provider = aws.network

  capacity = 300
  name     = "${var.project}-egress-domains"
  type     = "STATEFUL"

  rule_group {
    rule_variables {
      ip_sets {
        key = "HOME_NET"
        ip_set {
          definition = [var.internal_supernet]
        }
      }
    }

    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["TLS_SNI", "HTTP_HOST"]
        targets              = var.egress_allowed_domains
      }
    }
  }
}

########################################
# LOG -> S3 trong chinh account network
#
# KHONG gui sang log archive account: log FLOW rat nhieu va day la
# du lieu van hanh, khong phai bang chung kiem toan. Bang chung
# kiem toan la CloudTrail, va no da o log archive roi.
########################################

resource "aws_s3_bucket" "fw_logs" {
  count    = local.fw
  provider = aws.network

  bucket = "${var.project}-fw-logs-${var.network_account_id}"

  tags = { Name = "${var.project}-fw-logs" }
}

resource "aws_s3_bucket_public_access_block" "fw_logs" {
  count    = local.fw
  provider = aws.network

  bucket                  = aws_s3_bucket.fw_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "fw_logs" {
  count    = local.fw
  provider = aws.network

  bucket = aws_s3_bucket.fw_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Log FLOW ghi mot dong moi phien. Khong co lifecycle thi bucket nay
# phinh len am tham cho toi khi ai do nhin hoa don S3.
resource "aws_s3_bucket_lifecycle_configuration" "fw_logs" {
  count    = local.fw
  provider = aws.network

  bucket = aws_s3_bucket.fw_logs[0].id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = var.firewall_log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "fw_logs" {
  count    = local.fw
  provider = aws.network

  bucket = aws_s3_bucket.fw_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSLogDeliveryWrite"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.fw_logs[0].arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = var.network_account_id
          }
        }
      },
      {
        Sid       = "AWSLogDeliveryAclCheck"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.fw_logs[0].arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.network_account_id
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.fw_logs[0].arn,
          "${aws_s3_bucket.fw_logs[0].arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}

resource "aws_networkfirewall_logging_configuration" "main" {
  count    = local.fw
  provider = aws.network

  firewall_arn = aws_networkfirewall_firewall.main[0].arn

  logging_configuration {
    log_destination_config {
      log_type             = "ALERT"
      log_destination_type = "S3"
      log_destination = {
        bucketName = aws_s3_bucket.fw_logs[0].id
        prefix     = "alert"
      }
    }

    log_destination_config {
      log_type             = "FLOW"
      log_destination_type = "S3"
      log_destination = {
        bucketName = aws_s3_bucket.fw_logs[0].id
        prefix     = "flow"
      }
    }
  }

  depends_on = [aws_s3_bucket_policy.fw_logs]
}
