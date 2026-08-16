########################################
# NETWORK ACCOUNT: TGW + egress VPC
########################################

resource "aws_ec2_transit_gateway" "hub" {
  provider    = aws.network
  description = "${var.project} hub"

  default_route_table_association = "disable"
  default_route_table_propagation = "disable"

  # Tu dong chap nhan attachment tu account khac trong org.
  # Neu de "disable", moi attachment tu spoke phai duoc accept thu cong
  # bang aws_ec2_transit_gateway_vpc_attachment_accepter o account nay.
  auto_accept_shared_attachments = "enable"

  tags = { Name = "${var.project}-tgw" }
}

########################################
# RAM share TGW cho cac account spoke
#
# Day la manh ghep lam cho multi-account chay duoc.
# Trong cung mot Organization co bat RAM sharing thi share
# duoc tu dong chap nhan, khong can invitation.
########################################

resource "aws_ram_resource_share" "tgw" {
  provider = aws.network

  name                      = "${var.project}-tgw-share"
  allow_external_principals = false

  tags = { Name = "${var.project}-tgw-share" }
}

resource "aws_ram_resource_association" "tgw" {
  provider = aws.network

  resource_arn       = aws_ec2_transit_gateway.hub.arn
  resource_share_arn = aws_ram_resource_share.tgw.arn
}

resource "aws_ram_principal_association" "spokes" {
  provider = aws.network
  for_each = toset([var.spoke_a_account_id, var.spoke_b_account_id])

  principal          = each.value
  resource_share_arn = aws_ram_resource_share.tgw.arn
}

########################################
# Egress VPC
########################################

resource "aws_vpc" "egress" {
  provider = aws.network

  cidr_block           = var.egress_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-egress-vpc" }
}

resource "aws_internet_gateway" "egress" {
  provider = aws.network
  vpc_id   = aws_vpc.egress.id

  tags = { Name = "${var.project}-egress-igw" }
}

resource "aws_subnet" "egress_public" {
  provider = aws.network

  vpc_id                  = aws_vpc.egress.id
  cidr_block              = cidrsubnet(var.egress_vpc_cidr, 8, 0)
  availability_zone       = var.az
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-egress-public", Tier = "public" }
}

resource "aws_subnet" "egress_tgw" {
  provider = aws.network

  vpc_id            = aws_vpc.egress.id
  cidr_block        = cidrsubnet(var.egress_vpc_cidr, 12, 32)
  availability_zone = var.az

  tags = { Name = "${var.project}-egress-tgw", Tier = "tgw" }
}

resource "aws_eip" "nat" {
  provider = aws.network
  domain   = "vpc"

  tags = { Name = "${var.project}-nat-eip" }
}

resource "aws_nat_gateway" "egress" {
  provider = aws.network

  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.egress_public.id

  tags = { Name = "${var.project}-nat" }

  depends_on = [aws_internet_gateway.egress]
}

########################################
# Route table cua egress VPC
########################################

resource "aws_route_table" "egress_public" {
  provider = aws.network
  vpc_id   = aws_vpc.egress.id

  tags = { Name = "${var.project}-egress-public-rt" }
}

resource "aws_route" "egress_public_default" {
  provider = aws.network

  route_table_id         = aws_route_table.egress_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.egress.id
}

# *** DUONG VE - loi hay gap nhat ***
resource "aws_route" "egress_public_to_spokes" {
  provider = aws.network

  route_table_id         = aws_route_table.egress_public.id
  destination_cidr_block = var.supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.egress]
}

resource "aws_route_table_association" "egress_public" {
  provider = aws.network

  subnet_id      = aws_subnet.egress_public.id
  route_table_id = aws_route_table.egress_public.id
}

resource "aws_route_table" "egress_tgw" {
  provider = aws.network
  vpc_id   = aws_vpc.egress.id

  tags = { Name = "${var.project}-egress-tgw-rt" }
}

resource "aws_route" "egress_tgw_default" {
  provider = aws.network

  route_table_id         = aws_route_table.egress_tgw.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.egress.id
}

resource "aws_route_table_association" "egress_tgw" {
  provider = aws.network

  subnet_id      = aws_subnet.egress_tgw.id
  route_table_id = aws_route_table.egress_tgw.id
}

########################################
# Attachment cua chinh egress VPC
########################################

resource "aws_ec2_transit_gateway_vpc_attachment" "egress" {
  provider = aws.network

  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.egress.id
  subnet_ids         = [aws_subnet.egress_tgw.id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-tgwa-egress" }
}
