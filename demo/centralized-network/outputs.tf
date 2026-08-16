output "nat_public_ip" {
  description = "IP cong khai cua NAT. Moi spoke phai ra Internet bang IP nay."
  value       = aws_eip.nat.public_ip
}

output "transit_gateway_id" {
  value = aws_ec2_transit_gateway.hub.id
}

# one() tra ve phan tu duy nhat, hoac null khi count = 0.
# Dung [0] trong nhanh cua toan tu ba ngoi se loi khi resource khong duoc tao.
output "vpc_ids" {
  value = merge(
    {
      egress = aws_vpc.egress.id
    },
    { for k, v in aws_vpc.spoke : k => v.id },
    { ingress = one(aws_vpc.ingress[*].id) }
  )
}

output "test_instance_id" {
  description = "Dung cho: aws ssm start-session --target <id>"
  value       = one(aws_instance.test[*].id)
}

output "test_instance_private_ip" {
  value = one(aws_instance.test[*].private_ip)
}

output "alb_dns_name" {
  value = one(aws_lb.ingress[*].dns_name)
}

output "interface_endpoints_enabled" {
  value = var.enable_interface_endpoints ? var.interface_endpoint_services : []
}

output "estimated_hourly_cost_usd" {
  description = "Uoc tinh THO phi co dinh theo gio. Chua tinh data transfer."
  value = format(
    "~$%.3f/gio (~$%.2f/ngay)",
    local.hourly_cost,
    local.hourly_cost * 24
  )
}

locals {
  # Don gia tham khao ap-southeast-1, kiem tra lai bang Pricing Calculator
  cost_tgw_attachment = 0.05
  cost_nat_gateway    = 0.045
  cost_alb            = 0.0225
  cost_vpce_per_az    = 0.01
  cost_ec2_t3micro    = 0.0116

  attachment_count = length(var.spokes) + 1 + (var.enable_ingress ? 1 : 0)

  hourly_cost = (
    local.attachment_count * local.cost_tgw_attachment
    + local.cost_nat_gateway
    + (var.enable_ingress ? local.cost_alb : 0)
    + (var.enable_interface_endpoints ? length(var.interface_endpoint_services) * local.cost_vpce_per_az : 0)
    + (var.enable_test_instance ? local.cost_ec2_t3micro : 0)
  )
}

output "next_steps" {
  value = <<-EOT

    ================= BUOC TIEP THEO =================

    1. Vao EC2 trong spoke (chinh viec vao duoc = duong egress OK):
       aws ssm start-session --target ${coalesce(one(aws_instance.test[*].id), "<bat enable_test_instance>")} --region ${var.region}

    2. Trong session, kiem chung IP ra Internet:
       curl -s https://checkip.amazonaws.com
       => phai tra ve ${aws_eip.nat.public_ip}

    3. Xac nhan spoke KHONG co IGW:
       ./verify.sh

    4. XOA khi xong (quan trong - tranh tinh tien):
       terraform destroy -auto-approve

    ==================================================
  EOT
}
