########################################
# EGRESS VPC - duong ra Internet DUY NHAT cua ca landing zone
#
# CIDR subnet theo bang o doc 17 muc 3:
#   public  10.2.0.0/24   10.2.1.0/24
#   tgw     10.2.20.0/28  10.2.21.0/28
#
# SCP network_lock ben layer organization chan tao IGW/NAT/EIP o
# account workload. Account network duoc mien tru - day chinh la ly
# do co mien tru do.
########################################

resource "aws_vpc" "egress" {
  count    = local.enabled ? 1 : 0
  provider = aws.network

  cidr_block           = var.egress_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-egress-vpc" }
}

resource "aws_internet_gateway" "egress" {
  count    = local.enabled ? 1 : 0
  provider = aws.network

  vpc_id = aws_vpc.egress[0].id
  tags   = { Name = "${var.project}-egress-igw" }
}

resource "aws_subnet" "egress_public" {
  for_each = local.enabled ? local.azs : {}
  provider = aws.network

  vpc_id            = aws_vpc.egress[0].id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.egress_vpc_cidr, 8, each.value) # 10.2.0.0/24

  # Khong may cai nao o day duoc IP public tu dong. Chi NAT Gateway
  # co EIP, va no la resource rieng.
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-egress-public-${each.key}", Tier = "public" }
}

resource "aws_subnet" "egress_tgw" {
  for_each = local.enabled ? local.azs : {}
  provider = aws.network

  vpc_id            = aws_vpc.egress[0].id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.egress_vpc_cidr, 12, 320 + each.value * 16) # 10.2.20.0/28

  tags = { Name = "${var.project}-egress-tgw-${each.key}", Tier = "tgw" }
}

########################################
# NAT Gateway - MOT MOI AZ
#
# Dung chung mot NAT cho nhieu AZ thi re hon ~$33/thang, doi lai:
#   - moi goi tin cua AZ kia di cheo AZ, tra them tien truyen
#   - AZ chua NAT hong la CA landing zone mat duong ra Internet
#
# Doi thu hai moi la ly do that de khong dung chung.
########################################

resource "aws_eip" "nat" {
  for_each = local.enabled ? local.azs : {}
  provider = aws.network

  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip-${each.key}" }
}

resource "aws_nat_gateway" "egress" {
  for_each = local.enabled ? local.azs : {}
  provider = aws.network

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.egress_public[each.key].id

  tags = { Name = "${var.project}-nat-${each.key}" }

  depends_on = [aws_internet_gateway.egress]
}

########################################
# Route table
########################################

# Subnet public: ra Internet qua IGW.
resource "aws_route_table" "egress_public" {
  count    = local.enabled ? 1 : 0
  provider = aws.network

  vpc_id = aws_vpc.egress[0].id
  tags   = { Name = "${var.project}-egress-public-rt" }
}

resource "aws_route" "egress_public_default" {
  count    = local.enabled ? 1 : 0
  provider = aws.network

  route_table_id         = aws_route_table.egress_public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.egress[0].id
}

# *** DUONG VE - loi pho bien nhat cua ca mo hinh ***
#
# Doc 17 muc 4.1 in dam dung o day. Thieu dong nay thi goi tin tu
# spoke RA duoc Internet, nhung goi tra ve tu NAT khong biet duong
# quay lai spoke - no chi thay local route cua egress VPC.
#
# Trieu chung: moi ket noi ra ngoai deu timeout, trong khi tcpdump o
# NAT cho thay goi di ra binh thuong. Rat kho doan neu khong biet
# truoc.
resource "aws_route" "egress_public_to_internal" {
  count    = local.enabled ? 1 : 0
  provider = aws.network

  route_table_id         = aws_route_table.egress_public[0].id
  destination_cidr_block = var.internal_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub[0].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.egress]
}

resource "aws_route_table_association" "egress_public" {
  for_each = local.enabled ? local.azs : {}
  provider = aws.network

  subnet_id      = aws_subnet.egress_public[each.key].id
  route_table_id = aws_route_table.egress_public[0].id
}

# Subnet tgw: MOI AZ MOT BANG, tro vao NAT CUA CHINH AZ DO.
# Dung chung mot bang thi mot nua luong di cheo AZ va tra them tien
# truyen ma khong duoc gi.
resource "aws_route_table" "egress_tgw" {
  for_each = local.enabled ? local.azs : {}
  provider = aws.network

  vpc_id = aws_vpc.egress[0].id
  tags   = { Name = "${var.project}-egress-tgw-rt-${each.key}" }
}

resource "aws_route" "egress_tgw_default" {
  for_each = local.enabled ? local.azs : {}
  provider = aws.network

  route_table_id         = aws_route_table.egress_tgw[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.egress[each.key].id
}

resource "aws_route_table_association" "egress_tgw" {
  for_each = local.enabled ? local.azs : {}
  provider = aws.network

  subnet_id      = aws_subnet.egress_tgw[each.key].id
  route_table_id = aws_route_table.egress_tgw[each.key].id
}

########################################
# TGW attachment
########################################

resource "aws_ec2_transit_gateway_vpc_attachment" "egress" {
  count    = local.enabled ? 1 : 0
  provider = aws.network

  transit_gateway_id = aws_ec2_transit_gateway.hub[0].id
  vpc_id             = aws_vpc.egress[0].id
  subnet_ids         = [for z in var.availability_zones : aws_subnet.egress_tgw[z].id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-tgwa-egress" }
}
