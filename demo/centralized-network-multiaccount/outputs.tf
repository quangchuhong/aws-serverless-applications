output "nat_public_ip" {
  description = "Moi spoke account phai ra Internet bang IP nay"
  value       = aws_eip.nat.public_ip
}

output "transit_gateway_id" {
  value = aws_ec2_transit_gateway.hub.id
}

output "accounts" {
  value = {
    network = var.network_account_id
    spoke_a = var.spoke_a_account_id
    spoke_b = var.spoke_b_account_id
  }
}

output "spoke_a" {
  value = {
    vpc_id      = module.spoke_a.vpc_id
    cidr        = module.spoke_a.cidr
    instance_id = module.spoke_a.test_instance_id
    private_ip  = module.spoke_a.test_instance_private_ip
  }
}

output "spoke_b" {
  value = {
    vpc_id      = module.spoke_b.vpc_id
    cidr        = module.spoke_b.cidr
    instance_id = module.spoke_b.test_instance_id
    private_ip  = module.spoke_b.test_instance_private_ip
  }
}

locals {
  cost_tgw_attachment = 0.05
  cost_nat_gateway    = 0.045
  cost_vpce_per_az    = 0.01
  cost_ec2_t3micro    = 0.0116

  hourly_cost = (
    3 * local.cost_tgw_attachment # egress + 2 spoke
    + local.cost_nat_gateway
    + (var.enable_interface_endpoints ? length(var.interface_endpoint_services) * local.cost_vpce_per_az : 0)
    + (var.enable_test_instances ? 2 * local.cost_ec2_t3micro : 0)
  )
}

output "estimated_hourly_cost_usd" {
  description = "Uoc tinh THO phi co dinh. Chua tinh data transfer."
  value       = format("~$%.3f/gio (~$%.2f/ngay)", local.hourly_cost, local.hourly_cost * 24)
}

output "next_steps" {
  value = <<-EOT

    ============ KIEM CHUNG ============

    1. Vao EC2 o spoke A (phai assume role vao account do truoc):
       aws ssm start-session \
         --target ${coalesce(module.spoke_a.test_instance_id, "<bat enable_test_instances>")} \
         --region ${var.region} --profile spoke-a

    2. Trong session - IP ra Internet phai la NAT cua NETWORK account:
       curl -s https://checkip.amazonaws.com
       => ${aws_eip.nat.public_ip}

    3. Kiem chung cach ly giua hai ACCOUNT (phai timeout):
       ping -c 3 ${coalesce(module.spoke_b.test_instance_private_ip, "10.20.1.x")}

    4. XOA resource (account van con nguyen):
       terraform destroy -auto-approve

    ====================================
  EOT
}
