########################################
# GIA TRI DUNG TRONG HEREDOC
#
# one(...[*].id) tra ve NULL khi count = 0, va null KHONG noi suy
# duoc vao string template:
#
#   Error: Invalid template interpolation value
#   The expression result is null.
#
# Doi voi mot gan gia tri thi null vo hai - xem
# local.inspect_attachment_id ben tgw.tf. Trong heredoc thi no lam
# hong ca terraform plan, va hong o dung trang thai MAC DINH
# (enable = false) - trang thai ai cung gap dau tien.
#
# coalesce() thay null bang cho giu cho doc duoc.
########################################

locals {
  tgw_id_text = coalesce(
    one(aws_ec2_transit_gateway.hub[*].id),
    "<tgw-id: chay terraform apply truoc>"
  )

  fw_bucket_text = coalesce(
    one(aws_s3_bucket.fw_logs[*].id),
    "<bucket log firewall: chay terraform apply truoc>"
  )
}

output "enabled" {
  value = local.enabled
}

output "tgw_id" {
  description = "ID cua Transit Gateway. Account workload can no de attach."
  value       = one(aws_ec2_transit_gateway.hub[*].id)
}

output "tgw_arn" {
  value = one(aws_ec2_transit_gateway.hub[*].arn)
}

output "route_tables" {
  description = "ID cua ba route table TGW"
  value = {
    spokes   = one(aws_ec2_transit_gateway_route_table.spokes[*].id)
    security = one(aws_ec2_transit_gateway_route_table.security[*].id)
    egress   = one(aws_ec2_transit_gateway_route_table.egress[*].id)
  }
}

output "security_vpc_id" {
  value = one(aws_vpc.security[*].id)
}

output "egress_vpc_id" {
  value = one(aws_vpc.egress[*].id)
}

output "nat_public_ips" {
  description = <<-EOT
    IP cong khai cua NAT Gateway - moi AZ mot cai.

    Day la TOAN BO dia chi ma landing zone nay dung khi goi ra
    Internet. Dua danh sach nay cho doi tac de ho allowlist, va
    kiem lai khi them AZ.
  EOT
  value       = { for z, e in aws_eip.nat : z => e.public_ip }
}

output "firewall_endpoints" {
  description = "AZ -> firewall endpoint ID. Rong khi enable_firewall = false."
  value       = local.fw_endpoints
}

output "firewall_log_bucket" {
  value = one(aws_s3_bucket.fw_logs[*].id)
}

output "spokes_wired" {
  description = "Attachment da duoc noi vao route table"
  value       = keys(var.spoke_attachments)
}

########################################
# SINH CAU HINH CHO ACCOUNT WORKLOAD
#
# Layer nay khong tao duoc VPC o account khac (provider khong sinh
# dong duoc bang for_each). Nhung no sinh duoc khoi HCL de dan.
########################################

output "paste_spoke_vpc" {
  description = <<-EOT
    Khoi HCL toi thieu cho mot spoke VPC o account workload.

    Chay o account do, KHONG phai o day. Doi ten va CIDR truoc khi
    dung - dai spoke lay theo bang o doc 17 muc 3:
      NonProd  10.10.0.0/14
      Prod     10.20.0.0/14
  EOT
  value       = <<-EOT
    # ==== chay o ACCOUNT WORKLOAD ====

    variable "spoke_cidr" { default = "10.10.0.0/16" }

    resource "aws_vpc" "spoke" {
      cidr_block           = var.spoke_cidr
      enable_dns_support   = true
      enable_dns_hostnames = true
      tags                 = { Name = "spoke" }
    }

    # KHONG co aws_internet_gateway, KHONG co aws_nat_gateway.
    # SCP network_lock chan tao chung, va do la dung y muon:
    # duong ra Internet duy nhat la qua TGW -> firewall -> egress VPC.

    resource "aws_subnet" "tgw" {
      for_each          = toset(${jsonencode(var.availability_zones)})
      vpc_id            = aws_vpc.spoke.id
      availability_zone = each.value
      cidr_block        = cidrsubnet(var.spoke_cidr, 12, 320 + index(${jsonencode(var.availability_zones)}, each.value) * 16)
      tags              = { Name = "spoke-tgw-$${each.value}", Tier = "tgw" }
    }

    resource "aws_subnet" "private" {
      for_each          = toset(${jsonencode(var.availability_zones)})
      vpc_id            = aws_vpc.spoke.id
      availability_zone = each.value
      cidr_block        = cidrsubnet(var.spoke_cidr, 8, index(${jsonencode(var.availability_zones)}, each.value))
      tags              = { Name = "spoke-private-$${each.value}", Tier = "private" }
    }

    # TGW da duoc share qua RAM nen dung thang ID nay duoc.
    resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
      transit_gateway_id = "${local.tgw_id_text}"
      vpc_id             = aws_vpc.spoke.id
      subnet_ids         = [for s in aws_subnet.tgw : s.id]

      # BAT BUOC false o account thanh vien: chi chu so huu TGW moi
      # associate/propagate duoc. Bao layer network noi ho.
      transit_gateway_default_route_table_association = false
      transit_gateway_default_route_table_propagation = false

      tags = { Name = "tgwa-spoke" }
    }

    resource "aws_route_table" "private" {
      vpc_id = aws_vpc.spoke.id
      tags   = { Name = "spoke-private-rt" }
    }

    # MOT dong nay la toan bo duong ra cua spoke.
    resource "aws_route" "to_tgw" {
      route_table_id         = aws_route_table.private.id
      destination_cidr_block = "0.0.0.0/0"
      transit_gateway_id     = "${local.tgw_id_text}"
      depends_on             = [aws_ec2_transit_gateway_vpc_attachment.this]
    }

    resource "aws_route_table_association" "private" {
      for_each       = aws_subnet.private
      subnet_id      = each.value.id
      route_table_id = aws_route_table.private.id
    }

    # Gateway endpoint: MIEN PHI, va giu luu luong S3/DynamoDB khong
    # ra khoi VPC - khong ton tien NAT, khong ton chang TGW.
    resource "aws_vpc_endpoint" "s3" {
      vpc_id            = aws_vpc.spoke.id
      service_name      = "com.amazonaws.${var.region}.s3"
      vpc_endpoint_type = "Gateway"
      route_table_ids   = [aws_route_table.private.id]
    }

    output "attachment_id" { value = aws_ec2_transit_gateway_vpc_attachment.this.id }
  EOT
}

output "next_steps" {
  value = <<-EOT

    ══════════════════════ SAU KHI APPLY ══════════════════════

    1. HUB DA DUNG CHUA:

         aws ec2 describe-transit-gateways --profile <network> \
           --region ${var.region} \
           --query 'TransitGateways[].[TransitGatewayId,State]' --output table

         aws network-firewall describe-firewall \
           --firewall-name ${var.project}-fw --profile <network> \
           --region ${var.region} \
           --query 'FirewallStatus.Status' --output text
       # PHAI la READY. PROVISIONING keo dai vai phut la binh thuong.

    2. TGW DA SHARE CHUA - hoi tu ACCOUNT WORKLOAD, khong phai o day:

         aws ec2 describe-transit-gateways --profile <workload> \
           --region ${var.region} \
           --query 'TransitGateways[].TransitGatewayId' --output text

       Rong = RAM share chua toi. Kiem ram.amazonaws.com trong
       aws_service_access_principals ben layer organization.

    3. TAO SPOKE, ROI QUAY LAI NOI NO VAO - BUOC HAY QUEN NHAT:

       a) Chay khoi HCL o account workload:
            terraform output -raw paste_spoke_vpc

       b) Lay attachment ID:
            terraform output attachment_id     # o account workload

          hoac liet ke tat ca (chay o account network):
            aws ec2 describe-transit-gateway-attachments \
              --filters Name=transit-gateway-id,Values=${local.tgw_id_text} \
                        Name=resource-type,Values=vpc \
              --query 'TransitGatewayAttachments[].[TransitGatewayAttachmentId,ResourceOwnerId,State]' \
              --output table

       c) Dien vao spoke_attachments o terraform.tfvars CUA LAYER NAY,
          roi apply lai.

       BO BUOC (c) = attachment ton tai, State "available", va KHONG
       THUOC ROUTE TABLE NAO. Khong loi, khong canh bao, khong mot goi
       tin nao di qua. Co check block bao khi spoke_attachments rong,
       nhung no khong biet ban vua tao them cai thu ba.

    4. KIEM DUONG DI THAT - dung tin route table, gui goi tin:

       Tao mot EC2 trong spoke (khong can IP public, SSM di qua
       interface endpoint), roi:

         aws ssm start-session --target <instance-id> --profile <workload>
         # trong phien:
         curl -s -o /dev/null -w '%%{http_code}\n' https://checkip.amazonaws.com
         curl -s https://checkip.amazonaws.com

       IP tra ve PHAI nam trong nat_public_ips. Ra IP khac = co
       duong ra Internet nao do khong qua egress VPC.

    5. DOC ALERT LOG MOT TUAN TRUOC KHI BAT "drop":

         aws s3 ls s3://${local.fw_bucket_text}/alert/ --recursive \
           --profile <network> | tail

       Tim dong "UNMATCHED east-west" - do la ban do that ve ai dang
       goi ai. Viet east_west_rules tu do, roi moi doi firewall_mode
       thanh "drop".

    6. PHZ CHO SPOKE O ACCOUNT KHAC (neu dung interface endpoint):

       Terraform khong lam ho duoc - can provider cua ca hai account.

         # o account network:
         aws route53 create-vpc-association-authorization \
           --hosted-zone-id <zone-id> \
           --vpc VPCRegion=${var.region},VPCId=<vpc-id-cua-spoke>

         # o account workload:
         aws route53 associate-vpc-with-hosted-zone \
           --hosted-zone-id <zone-id> \
           --vpc VPCRegion=${var.region},VPCId=<vpc-id-cua-spoke>

       Lay zone id: terraform output endpoint_zone_ids

    ═══════════════════════════════════════════════════════════

  EOT
}

output "endpoint_zone_ids" {
  description = "Dich vu -> zone ID cua PHZ. Dung cho buoc 6 o tren."
  value       = { for k, z in aws_route53_zone.endpoint : k => z.zone_id }
}
