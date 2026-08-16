########################################
# EGRESS VPC - duong ra Internet duy nhat cua ca LZ
########################################

resource "aws_vpc" "egress" {
  cidr_block           = var.egress_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-egress-vpc" }
}

resource "aws_internet_gateway" "egress" {
  vpc_id = aws_vpc.egress.id
  tags   = { Name = "${var.project}-egress-igw" }
}

resource "aws_subnet" "egress_public" {
  vpc_id                  = aws_vpc.egress.id
  cidr_block              = cidrsubnet(var.egress_vpc_cidr, 8, 0)
  availability_zone       = var.az
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-egress-public", Tier = "public" }
}

resource "aws_subnet" "egress_tgw" {
  vpc_id            = aws_vpc.egress.id
  cidr_block        = cidrsubnet(var.egress_vpc_cidr, 12, 32)
  availability_zone = var.az

  tags = { Name = "${var.project}-egress-tgw", Tier = "tgw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip" }
}

resource "aws_nat_gateway" "egress" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.egress_public.id

  tags = { Name = "${var.project}-nat" }

  depends_on = [aws_internet_gateway.egress]
}

########################################
# Route table
########################################

resource "aws_route_table" "egress_public" {
  vpc_id = aws_vpc.egress.id
  tags   = { Name = "${var.project}-egress-public-rt" }
}

resource "aws_route" "egress_public_default" {
  route_table_id         = aws_route_table.egress_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.egress.id
}

# *** DUONG VE ***
# Loi pho bien nhat cua ca mo hinh: thieu dong nay thi goi tin
# tu spoke ra duoc Internet, nhung goi tra ve tu NAT khong biet
# duong quay lai spoke -> timeout, rat kho doan nguyen nhan.
resource "aws_route" "egress_public_to_internal" {
  route_table_id         = aws_route_table.egress_public.id
  destination_cidr_block = var.internal_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.egress]
}

resource "aws_route_table_association" "egress_public" {
  subnet_id      = aws_subnet.egress_public.id
  route_table_id = aws_route_table.egress_public.id
}

resource "aws_route_table" "egress_tgw" {
  vpc_id = aws_vpc.egress.id
  tags   = { Name = "${var.project}-egress-tgw-rt" }
}

resource "aws_route" "egress_tgw_default" {
  route_table_id         = aws_route_table.egress_tgw.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.egress.id
}

resource "aws_route_table_association" "egress_tgw" {
  subnet_id      = aws_subnet.egress_tgw.id
  route_table_id = aws_route_table.egress_tgw.id
}

resource "aws_ec2_transit_gateway_vpc_attachment" "egress" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.egress.id
  subnet_ids         = [aws_subnet.egress_tgw.id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-tgwa-egress" }
}
