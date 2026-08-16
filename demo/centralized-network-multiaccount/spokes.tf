########################################
# Spoke VPC o cac account KHAC
########################################

module "spoke_a" {
  source = "./modules/spoke"

  providers = { aws = aws.spoke_a }

  name                 = "app-dev"
  project              = var.project
  cidr                 = var.spoke_a_cidr
  region               = var.region
  az                   = var.az
  supernet             = var.supernet
  transit_gateway_id   = aws_ec2_transit_gateway.hub.id
  enable_test_instance = var.enable_test_instances

  # TGW phai duoc share TRUOC khi account spoke attach vao
  depends_on = [aws_ram_principal_association.spokes]
}

module "spoke_b" {
  source = "./modules/spoke"

  providers = { aws = aws.spoke_b }

  name                 = "app-prod"
  project              = var.project
  cidr                 = var.spoke_b_cidr
  region               = var.region
  az                   = var.az
  supernet             = var.supernet
  transit_gateway_id   = aws_ec2_transit_gateway.hub.id
  enable_test_instance = var.enable_test_instances

  depends_on = [aws_ram_principal_association.spokes]
}

########################################
# TGW route table
#
# QUAN TRONG: association va propagation PHAI lam o account
# so huu TGW (network account), du attachment thuoc account khac.
# Day la ly do chung nam o day chu khong nam trong module spoke.
########################################

locals {
  spoke_attachments = {
    "app-dev"  = module.spoke_a.attachment_id
    "app-prod" = module.spoke_b.attachment_id
  }
}

resource "aws_ec2_transit_gateway_route_table" "spokes" {
  provider           = aws.network
  transit_gateway_id = aws_ec2_transit_gateway.hub.id

  tags = { Name = "${var.project}-rtb-spokes" }
}

resource "aws_ec2_transit_gateway_route_table" "egress" {
  provider           = aws.network
  transit_gateway_id = aws_ec2_transit_gateway.hub.id

  tags = { Name = "${var.project}-rtb-egress" }
}

# Spoke dung rtb-spokes
resource "aws_ec2_transit_gateway_route_table_association" "spokes" {
  provider = aws.network
  for_each = local.spoke_attachments

  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

# Egress VPC dung rtb-egress
resource "aws_ec2_transit_gateway_route_table_association" "egress" {
  provider = aws.network

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

# Egress hoc duong toi moi spoke (de goi tra loi ve dung cho)
resource "aws_ec2_transit_gateway_route_table_propagation" "spokes_to_egress" {
  provider = aws.network
  for_each = local.spoke_attachments

  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

# Spoke CHI biet duong ra Internet.
# Khong propagate tu spoke khac -> app-dev khong thay app-prod.
resource "aws_ec2_transit_gateway_route" "spokes_default" {
  provider = aws.network

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}
