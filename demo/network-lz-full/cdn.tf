########################################
# CloudFront + AWS WAF
#
# Chi tao khi enable_cdn = true.
#
# Chi phi: gan nhu $0 cho demo.
#   - CloudFront: free tier 1 TB + 10 trieu request/thang (vinh vien)
#   - WAF Web ACL: ~$5/thang, chia theo gio -> ~$0.007/gio
#   - Moi rule group: ~$1/thang -> ~$0.0014/gio
#   => Phien 4 tieng khoang $0.05
#
# CAI GIA THAT LA THOI GIAN:
#   apply   ~5-15 phut (CloudFront deploy toan cau)
#   destroy ~15-20 phut (phai disable truoc roi moi delete duoc)
########################################

locals {
  cdn = var.enable_cdn && var.enable_ingress ? 1 : 0
}

# WAF cho CloudFront BAT BUOC tao o us-east-1, du CloudFront la global.
# Dung CUNG bo tag voi provider chinh - neu khong, WAF Web ACL se
# thieu tag CostCenter/Owner/Environment va lot khoi bao cao chi phi.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.common_tags
  }
}

########################################
# Bi mat de F5/app kiem tra request co di qua CDN khong.
# Demo dung nginx nen chua kiem tra, nhung van sinh ra de
# code giong voi thiet ke that (doc 14 muc 7.1).
########################################

resource "random_password" "origin_verify" {
  count   = local.cdn
  length  = 32
  special = false
}

########################################
# AWS WAF Web ACL
########################################

resource "aws_wafv2_web_acl" "cdn" {
  count    = local.cdn
  provider = aws.us_east_1

  name        = "${var.project}-cdn-waf"
  description = "WAF cho CloudFront - giai doan 1, thay tam cho F5"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  ########################################
  # Rate limit - chan IP goi qua nhieu
  ########################################
  rule {
    name     = "rate-limit"
    priority = 10

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  ########################################
  # Managed rule group cua AWS
  #
  # override_action = none  -> rule hoat dong binh thuong (chan)
  # override_action = count -> chi dem, khong chan (dung khi moi bat)
  ########################################
  dynamic "rule" {
    for_each = { for i, n in var.waf_managed_rule_groups : n => i }

    content {
      name     = rule.key
      priority = 20 + rule.value

      override_action {
        dynamic "none" {
          for_each = var.waf_mode == "block" ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = var.waf_mode == "count" ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.key
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = replace(rule.key, "AWSManagedRules", "")
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-cdn-waf"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${var.project}-cdn-waf" }
}

########################################
# CloudFront
########################################

data "aws_cloudfront_cache_policy" "disabled" {
  count = local.cdn
  name  = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  count = local.cdn
  name  = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "main" {
  count = local.cdn

  enabled     = true
  comment     = "${var.project} ingress"
  price_class = var.cdn_price_class

  origin {
    domain_name = aws_lb.ingress[0].dns_name
    origin_id   = "ingress-nlb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # Demo: NLB nghe HTTP:80
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Lop chan di vong qua CDN thu hai (ngoai security group).
    # That: F5 kiem tra header nay va tra 403 neu thieu.
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify[0].result
    }
  }

  default_cache_behavior {
    target_origin_id       = "ingress-nlb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    # Demo tat cache de moi request deu toi origin - de quan sat
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Dung certificate mac dinh cua CloudFront (*.cloudfront.net).
  # Nho vay KHONG can mua domain, khong can Route 53, khong can ACM.
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  web_acl_id = aws_wafv2_web_acl.cdn[0].arn

  tags = { Name = "${var.project}-cdn" }
}
