########################################
# EGRESS VPC - duong ra Internet duy nhat cua ca LZ
#
# CIDR subnet theo bang o doc 17 muc 3:
#   public  10.2.0.0/24   10.2.1.0/24   10.2.2.0/24
#   tgw     10.2.20.0/28  10.2.21.0/28  10.2.22.0/28
#
# Dai tgw bat dau tu .20 chu khong .2 la co ly do: voi 3 AZ thi
# public chiem toi 10.2.2.0/24, dam thang vao 10.2.2.0/28 neu dat
# tgw ngay sau public.
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
  for_each = local.azs

  vpc_id            = aws_vpc.egress.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.egress_vpc_cidr, 8, each.value) # 10.2.<i>.0/24

  # Chi NAT Gateway co IP public o day, va no la resource rieng.
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-egress-public-${each.key}", Tier = "public" }
}

resource "aws_subnet" "egress_tgw" {
  for_each = local.azs

  vpc_id            = aws_vpc.egress.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.egress_vpc_cidr, 12, 320 + each.value * 16) # 10.2.2<i>.0/28

  tags = { Name = "${var.project}-egress-tgw-${each.key}", Tier = "tgw" }
}

########################################
# NAT Gateway - MOT MOI AZ
#
# Dung chung mot NAT cho nhieu AZ thi re hon ~$33/thang, doi lai:
#   - luu luong cua AZ kia di cheo AZ, tra them phi truyen
#   - AZ chua NAT hong = CA LZ mat duong ra Internet
#
# Doi thu hai moi la ly do that.
########################################

resource "aws_eip" "nat" {
  for_each = local.azs

  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip-${each.key}" }
}

resource "aws_nat_gateway" "egress" {
  for_each = local.azs

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.egress_public[each.key].id

  tags = { Name = "${var.project}-nat-${each.key}" }

  depends_on = [aws_internet_gateway.egress]
}

########################################
# Route table
########################################

# Subnet public: ra Internet qua IGW. Mot bang dung chung duoc - moi
# AZ deu ra cung mot IGW.
resource "aws_route_table" "egress_public" {
  vpc_id = aws_vpc.egress.id
  tags   = { Name = "${var.project}-egress-public-rt" }
}

resource "aws_route" "egress_public_default" {
  route_table_id         = aws_route_table.egress_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.egress.id
}

# *** DUONG VE - loi pho bien nhat cua ca mo hinh ***
#
# Doc 17 muc 4.1 in dam dung o day. Thieu dong nay thi goi tin tu
# spoke RA duoc Internet, nhung goi tra ve tu NAT khong biet duong
# quay lai spoke - no chi thay local route cua egress VPC.
#
# Trieu chung: moi ket noi ra ngoai deu timeout, trong khi tcpdump o
# NAT cho thay goi di ra binh thuong.
resource "aws_route" "egress_public_to_internal" {
  route_table_id         = aws_route_table.egress_public.id
  destination_cidr_block = var.internal_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.egress]
}

resource "aws_route_table_association" "egress_public" {
  for_each = local.azs

  subnet_id      = aws_subnet.egress_public[each.key].id
  route_table_id = aws_route_table.egress_public.id
}

# Subnet tgw: MOI AZ MOT BANG, tro vao NAT CUA CHINH AZ DO.
#
# Day la ly do khong dung chung mot bang duoc: mot bang chi tro vao
# duoc mot NAT, nen mot nua luu luong se di cheo AZ - tra them phi
# truyen ma khong duoc gi, va mat luon tinh doc lap giua hai AZ.
resource "aws_route_table" "egress_tgw" {
  for_each = local.azs

  vpc_id = aws_vpc.egress.id
  tags   = { Name = "${var.project}-egress-tgw-rt-${each.key}" }
}

resource "aws_route" "egress_tgw_default" {
  for_each = local.azs

  route_table_id         = aws_route_table.egress_tgw[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.egress[each.key].id
}

resource "aws_route_table_association" "egress_tgw" {
  for_each = local.azs

  subnet_id      = aws_subnet.egress_tgw[each.key].id
  route_table_id = aws_route_table.egress_tgw[each.key].id
}

########################################
# TGW attachment - mot chan o MOI AZ
#
# Thieu mot AZ o day thi TGW khong co duong xuong AZ do, va luu luong
# cua AZ do phai vong qua AZ khac.
########################################

resource "aws_ec2_transit_gateway_vpc_attachment" "egress" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.egress.id
  subnet_ids         = [for z in var.availability_zones : aws_subnet.egress_tgw[z].id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-tgwa-egress" }
}
