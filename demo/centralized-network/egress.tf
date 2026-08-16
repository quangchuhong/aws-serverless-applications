########################################
# EGRESS VPC - IGW + NAT + route
########################################

resource "aws_internet_gateway" "egress" {
  vpc_id = aws_vpc.egress.id
  tags   = { Name = "${var.project}-egress-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip" }
}

# Demo dung 1 NAT o 1 AZ de tiet kiem.
# Production phai co NAT o MOI AZ (xem doc 13).
resource "aws_nat_gateway" "egress" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.egress_public.id

  tags = { Name = "${var.project}-nat" }

  depends_on = [aws_internet_gateway.egress]
}

########################################
# Route table: subnet chua NAT
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
# Thieu route nay la loi pho bien nhat cua mo hinh nay:
# goi tin tu spoke ra duoc Internet, nhung goi tra ve tu NAT
# khong biet duong quay lai spoke -> timeout kho doan.
resource "aws_route" "egress_public_to_spokes" {
  route_table_id         = aws_route_table.egress_public.id
  destination_cidr_block = var.supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.egress]
}

resource "aws_route_table_association" "egress_public" {
  subnet_id      = aws_subnet.egress_public.id
  route_table_id = aws_route_table.egress_public.id
}

########################################
# Route table: subnet chua ENI cua TGW
########################################

resource "aws_route_table" "egress_tgw" {
  vpc_id = aws_vpc.egress.id
  tags   = { Name = "${var.project}-egress-tgw-rt" }
}

# Traffic tu spoke di vao day roi ra NAT.
# Production: tro ve NAT CUNG AZ de tranh phi cross-AZ.
resource "aws_route" "egress_tgw_default" {
  route_table_id         = aws_route_table.egress_tgw.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.egress.id
}

resource "aws_route_table_association" "egress_tgw" {
  subnet_id      = aws_subnet.egress_tgw.id
  route_table_id = aws_route_table.egress_tgw.id
}
