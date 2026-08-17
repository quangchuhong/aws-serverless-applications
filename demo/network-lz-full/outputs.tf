output "mode" {
  value = join(" | ", compact([
    var.enable_firewall ? "Network Firewall (${var.firewall_mode})" : "khong firewall",
    var.enable_cdn ? "CloudFront + WAF (${var.waf_mode})" : "",
    var.enable_appliances ? "Palo Alto + F5" : "",
  ]))
}

output "nat_public_ip" {
  description = "Moi spoke phai ra Internet bang IP nay"
  value       = aws_eip.nat.public_ip
}

output "transit_gateway_id" {
  value = aws_ec2_transit_gateway.hub.id
}

output "security_vpc_id" {
  value = one(aws_vpc.security[*].id)
}

output "firewall_endpoint_id" {
  value = local.fw_endpoint_id
}

output "nlb_dns_name" {
  value = one(aws_lb.ingress[*].dns_name)
}

output "cloudfront_domain" {
  description = "Hostname mac dinh cua CloudFront - khong can mua domain"
  value       = one(aws_cloudfront_distribution.main[*].domain_name)
}

output "waf_web_acl_arn" {
  value = one(aws_wafv2_web_acl.cdn[*].arn)
}

output "appliances" {
  description = "Palo Alto va F5 - null khi enable_appliances = false"
  value = {
    palo_alto_id    = one(aws_instance.palo_alto[*].id)
    f5_id           = one(aws_instance.f5[*].id)
    f5_private_ip   = one(aws_instance.f5[*].private_ip)
    gwlb_endpoint   = one(aws_vpc_endpoint.gwlbe[*].id)
    f5_config_s3    = one(aws_s3_bucket.f5_config[*].id)
    f5_admin_secret = one(aws_secretsmanager_secret.f5_admin[*].name)
  }
}

output "firewall_log_bucket" {
  value = one(aws_s3_bucket.fw_logs[*].id)
}

output "instances" {
  value = {
    for k, v in aws_instance.test : k => {
      id         = v.id
      private_ip = v.private_ip
      vpc_cidr   = var.spokes[k].cidr
    }
  }
}

########################################
# Uoc tinh chi phi
########################################

locals {
  c_tgw_attach = 0.05
  c_nat        = 0.045
  c_fw         = 0.395
  c_nlb        = 0.0225
  c_vpce       = 0.01
  c_ec2        = 0.0116

  # WAF: Web ACL ~$5/thang + ~$1/thang moi rule group, chia theo gio.
  # CloudFront: $0 trong free tier (1 TB + 10 trieu request/thang).
  c_waf_acl  = 5.0 / 730
  c_waf_rule = 1.0 / 730

  # Appliance: EC2 + license Marketplace tinh theo gio.
  # Gia license dao dong RAT LON theo bundle - day chi la uoc tinh tho,
  # kiem tra gia that tren trang Marketplace cho dung bundle ban dung.
  c_gwlb      = 0.0125
  c_gwlbe     = 0.01
  c_palo_alto = 1.50 # EC2 m5.xlarge (~$0.24) + license (~$1.3)
  c_f5        = 1.50 # EC2 m5.xlarge (~$0.24) + license (~$1.3)

  n_attach = length(var.spokes) + 1 + local.fw + local.ing

  hourly = (
    local.n_attach * local.c_tgw_attach
    + local.c_nat
    + (var.enable_firewall ? local.c_fw : 0)
    + (var.enable_ingress ? local.c_nlb : 0)
    + (var.enable_firewall && var.enable_interface_endpoints ? length(var.interface_endpoint_services) * local.c_vpce : 0)
    + (var.enable_test_instances ? length(var.spokes) * local.c_ec2 : 0)
    + (local.cdn > 0 ? local.c_waf_acl + (length(var.waf_managed_rule_groups) + 1) * local.c_waf_rule : 0)
    + (local.app_on > 0 ? local.c_gwlb + local.c_gwlbe + local.c_palo_alto + local.c_f5 : 0)
  )
}

output "estimated_cost" {
  description = "Uoc tinh THO phi co dinh. Chua tinh data transfer."
  value       = format("~$%.3f/gio  |  ~$%.2f/ngay  |  ~$%.0f/thang", local.hourly, local.hourly * 24, local.hourly * 730)
}

output "next_steps" {
  value = <<-EOT

    ══════════════════ KIEM CHUNG ══════════════════

    1. Vao EC2 o ${local.first_spoke} (vao duoc = duong egress OK):
       aws ssm start-session --target ${try(aws_instance.test[local.first_spoke].id, "<bat enable_test_instances>")} --region ${var.region}

    2. Trong session - IP ra Internet phai la NAT:
       curl -s https://checkip.amazonaws.com
       => ${aws_eip.nat.public_ip}

    3. Chay kiem chung tu dong:
       ./verify.sh

    4. Ingress:
    ${local.cdn > 0 ?
  "   curl https://${aws_cloudfront_distribution.main[0].domain_name}\n       (goi thang vao NLB se bi CHAN - origin da khoa theo CloudFront)" :
"   curl http://${try(aws_lb.ingress[0].dns_name, "<bat enable_ingress>")}"}

    5. XOA khi xong:
       ./teardown.sh${local.cdn > 0 ? "   ← CloudFront lam destroy cham ~15-20 phut" : ""}

    ════════════════════════════════════════════════
    Chi phi hien tai: ${format("~$%.3f/gio", local.hourly)}
    ════════════════════════════════════════════════
  EOT
}
