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

  # MOT endpoint moi AZ - bat buoc, khong phai lua chon: subnet o AZ-a
  # khong tro duoc vao endpoint nam o AZ-b.
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
# sync_states la mot SET, khong phai list co thu tu - nen KHONG duoc
# lay theo chi so. Phai lap thanh map AZ -> endpoint id roi tra cuu.
#
# Lay nham endpoint cua AZ khac thi luu luong di cheo AZ va firewall
# stateful chi thay nua phien.
########################################

locals {
  fw_endpoints = var.enable_firewall ? {
    for st in tolist(aws_networkfirewall_firewall.main[0].firewall_status[0].sync_states) :
    st.availability_zone => tolist(st.attachment)[0].endpoint_id
  } : {}
}

########################################
# Policy
########################################

locals {
  # alert = chi ghi log, KHONG chan. Luon dung che do nay dau tien.
  # drop  = chan that.
  stateful_default = var.firewall_mode == "drop" ? ["aws:drop_established", "aws:alert_established"] : ["aws:alert_established"]

  # CIDR cua MOI spoke - local lan remote - de sinh rule mesh.
  #
  # Dung var.spokes chu khong phai local_spokes: mesh la de do duong
  # di GIUA CAC ACCOUNT, nen spoke remote la phan quan trong nhat. Bo
  # chung ra thi mesh chi con noi cac VPC trong cung mot account -
  # dung thu khong can kiem chung.
  #
  # sort() de thu tu on dinh: rule string doi thu tu la rule group bi
  # thay the moi lan plan, va o STRICT_ORDER thi thu tu con doi ca y
  # nghia. Cung ho voi loi 39.
  mesh_cidrs = sort([for k, v in var.spokes : v.cidr])
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

    # RULE GROUP CUA LOP VAN HANH - state khac, doi chu khac.
    #
    # Xem var.ops_rule_group_arns. Khoi nay rong o lan apply dau (chua
    # co ops/), va do la trang thai dung: policy khong the tro toi mot
    # ARN chua ton tai.
    #
    # ARN o day duoc tao boi thu muc ops/. Neu ai do chay `terraform
    # destroy` ben ops/ ma khong go ARN khoi bien nay truoc, layer nay
    # se hong o lan apply ke tiep voi loi bao khong tim thay rule group
    # - dung nhung khong noi ai xoa. teardown ben ops/ nhac lai dieu do.
    dynamic "stateful_rule_group_reference" {
      for_each = var.ops_rule_group_arns
      content {
        priority     = 150 + stateful_rule_group_reference.key
        resource_arn = stateful_rule_group_reference.value
      }
    }

    stateful_rule_group_reference {
      priority     = 200
      resource_arn = aws_networkfirewall_rule_group.egress_domains[0].arn
    }
  }
}

# Lop ops chi co cho cam khi firewall dang bat. Khong co check nay thi
# ai do dat ops_rule_group_arns voi enable_firewall = false se thay
# apply chay tron va khong hieu vi sao rule cua minh khong co tac dung:
# policy khong duoc tao, nen khong co gi doc rule group ca.
check "ops_rule_groups_are_attached" {
  assert {
    condition     = length(var.ops_rule_group_arns) == 0 || var.enable_firewall
    error_message = "ops_rule_group_arns co ${length(var.ops_rule_group_arns)} ARN nhung enable_firewall = false. Rule group van ton tai va van tinh phi capacity, nhung KHONG policy nao doc no - moi rule trong lop ops dang khong lam gi."
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

        # LUONG HA TANG THU HAI - SSM qua interface endpoint.
        #
        # Khi enable_interface_endpoints = true, PHZ tro ten dich vu AWS
        # vao IP NOI BO trong security VPC. Nghia la SSM agent cua moi
        # EC2 goi 443 tu spoke sang security VPC - va luong do di qua
        # chinh firewall nay.
        #
        # Thieu rule nay thi che do drop lam MAT SSM O MOI SPOKE. Va
        # trieu chung khong he chi vao firewall:
        #   - Session Manager bao "not connected"
        #   - instance van chay, van healthy trong console
        #   - verify.sh muc 7 tra ve chuoi rong, doc nhu EC2 chua boot
        #
        # Voi spoke o account khac thi con te hon: khong co duong nao
        # khac vao instance do, nen mat SSM la mat luon kha nang vao xem.
        var.enable_firewall && var.enable_interface_endpoints ? [
          "pass tcp ${var.internal_supernet} any -> ${var.security_vpc_cidr} 443 (msg:\"INFRA ssm to interface endpoint\"; sid:1810; rev:1;)",
        ] : [],

        # LUONG HA TANG THU BA - health check cua NLB doi tac.
        #
        # NLB trong 3rd-party VPC do suc khoe target nam o spoke, va
        # luong do di qua chinh firewall nay. Thieu rule: target group
        # bao unhealthy, NLB tra ve loi, va doi tac bao "dich vu cua
        # ban hong" - trong khi dich vu hoan toan binh thuong.
        #
        # CHI health check va CHI cong dich vu. Con AI duoc goi CAI GI
        # thi khai trong catalog cua lop ops - xem ops/catalog/partners.yaml.
        var.enable_partner_vpn ? [
          format(
            "pass tcp %s any -> %s %d (msg:\"INFRA partner nlb healthcheck\"; sid:1820; rev:1;)",
            var.partner_vpc_cidr, var.internal_supernet, var.partner_service_port,
          ),
        ] : [],

        # MESH THU NGHIEM - sinh tu east_west_mesh_ports.
        #
        # Mo mot port giua MOI cap spoke de do duong di. Khac
        # east_west_rules o cho: rules la luat that, khai tay tung
        # chieu; mesh la phep thu, sinh tu dong va nen tat sau khi do.
        #
        # sid bat dau tu 1700 de khong dam vao dai cua east_west_rules
        # (1000+) hay ha tang (1800+).
        flatten([
          for pi, port in var.east_west_mesh_ports : [
            for i, a in local.mesh_cidrs : [
              for j, b in local.mesh_cidrs :
              format(
                "pass tcp %s any -> %s %d (msg:\"MESH %s to %s\"; sid:%d; rev:1;)",
                a, b, port, a, b, 1700 + pi * 100 + i * 10 + j
              ) if i != j
            ]
          ]
        ]),

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
    # PHAI KHAI DUNG RULE ORDER VOI POLICY - loi 47.
    #
    # Policy o tren dat stateful_engine_options.rule_order =
    # STRICT_ORDER. Khi do MOI rule group duoc tham chieu cung phai
    # khai STRICT_ORDER. Thieu o day thi CreateFirewallPolicy bao:
    #
    #   InvalidRequestException: ResourceArn has invalid rule order,
    #   context: StatefulRuleGroupReferences[1].ResourceArn
    #
    # Mac dinh cua rule group la DEFAULT_ACTION_ORDER, nen "khong khai"
    # KHONG phai la "thua ke tu policy" - no la mot lua chon khac han.
    #
    # terraform plan KHONG BAT DUOC loi nay: rule group va policy la
    # hai resource rieng, plan khong doi chieu thuoc tinh giua chung.
    # Chi API tu choi luc apply. plan-check.sh chay 9 to hop, bao 136
    # resource cho nhanh firewall, va van khong thay.
    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }

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
