########################################
# AWS NETWORK FIREWALL
#
# Khoan dat nhat cua demo: ~$0.395/gio moi endpoint.
# Chi tao khi enable_firewall = true.
########################################

resource "aws_networkfirewall_firewall" "main" {
  count = local.fw

  name                = "${var.project}-fw"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.main[0].arn
  vpc_id              = aws_vpc.security[0].id

  # ephemeral = true  -> tat bao ve, terraform destroy chay tron
  # ephemeral = false -> bat bao ve that
  #
  # Xoa firewall la moi route tro vao endpoint cua no thanh mo coi,
  # va CA MANG mat ket noi - khong chi mat thanh tra. Muon xoa that
  # thi doi ephemeral = false thanh true, apply rieng mot lan, roi
  # moi destroy.
  delete_protection        = !var.ephemeral
  subnet_change_protection = !var.ephemeral

  # De false o ca hai che do: doi policy la viec van hanh binh thuong
  # (them rule, doi alert sang drop), khong phai viec can chan.
  firewall_policy_change_protection = false

  subnet_mapping {
    subnet_id = aws_subnet.security_firewall[0].id
  }

  tags = { Name = "${var.project}-fw" }
}

# Endpoint ID de dung trong route table.
# Cau truc: firewall_status[0].sync_states[*].attachment[0].endpoint_id
locals {
  fw_endpoint_id = var.enable_firewall ? tolist(aws_networkfirewall_firewall.main[0].firewall_status[0].sync_states)[0].attachment[0].endpoint_id : null
}

########################################
# Policy
########################################

locals {
  # alert = chi ghi log, KHONG chan. Luon dung che do nay dau tien.
  # drop  = chan that.
  stateful_default = var.firewall_mode == "drop" ? ["aws:drop_established", "aws:alert_established"] : ["aws:alert_established"]
}

resource "aws_networkfirewall_firewall_policy" "main" {
  count = local.fw

  name = "${var.project}-policy"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    # STRICT_ORDER de priority co y nghia
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
# Route KHONG doi. Chi rule nay + security group.
########################################

resource "aws_networkfirewall_rule_group" "east_west" {
  count = local.fw

  capacity = 100
  name     = "${var.project}-east-west"
  type     = "STATEFUL"

  rule_group {
    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }

    rules_source {
      rules_string = join("\n", concat(
        # Rule allow sinh tu var.east_west_rules
        [
          for i, r in var.east_west_rules :
          format(
            "pass tcp %s any -> %s %d (msg:\"ALLOW %s\"; sid:%d; rev:1;)",
            r.from_cidr, r.to_cidr, r.port, r.note, 1000 + i
          )
        ],

        # Luong HA TANG - phai co, neu khong che do drop se lam hong ingress.
        # NLB o ingress VPC goi xuong app trong spoke: ca health check lan
        # traffic that. Khong co rule nay thi o che do drop, target group
        # unhealthy va NLB tra ve loi - rat de nham la loi routing.
        var.enable_ingress ? [
          "pass tcp ${var.ingress_vpc_cidr} any -> ${var.internal_supernet} 80 (msg:\"INFRA nlb to app\"; sid:1800; rev:1;)",
        ] : [],

        [
          # ICMP noi bo de troubleshoot
          "pass icmp ${var.internal_supernet} any -> ${var.internal_supernet} any (msg:\"internal icmp\"; sid:1900; rev:1;)",
          # Ghi log moi luong noi bo KHONG khop rule nao o tren.
          # Doc alert log cua rule nay = ban do that ve ai dang goi ai.
          "alert ip ${var.internal_supernet} any -> ${var.internal_supernet} any (msg:\"UNMATCHED east-west\"; sid:1999; rev:1;)",
        ]
      ))
    }
  }
}

########################################
# EGRESS: domain allowlist theo TLS SNI / HTTP Host
########################################

resource "aws_networkfirewall_rule_group" "egress_domains" {
  count = local.fw

  capacity = 200
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
# Logging -> S3
########################################

resource "aws_s3_bucket" "fw_logs" {
  count = local.fw

  bucket        = "${var.project}-fw-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.ephemeral # ephemeral=false: con log thi destroy dung lai

  tags = { Name = "${var.project}-fw-logs" }
}

resource "aws_s3_bucket_public_access_block" "fw_logs" {
  count = local.fw

  bucket                  = aws_s3_bucket.fw_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "fw_logs" {
  count = local.fw

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
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
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
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

resource "aws_networkfirewall_logging_configuration" "main" {
  count = local.fw

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
