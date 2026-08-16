########################################
# EGRESS VPC - duong ra Internet duy nhat
########################################

resource "aws_vpc" "egress" {
  cidr_block           = var.egress_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-egress-vpc" }
}

# Subnet chua NAT Gateway, co duong ra IGW
resource "aws_subnet" "egress_public" {
  vpc_id                  = aws_vpc.egress.id
  cidr_block              = cidrsubnet(var.egress_vpc_cidr, 8, 0)
  availability_zone       = var.azs[0]
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-egress-public", Tier = "public" }
}

# Subnet rieng cho ENI cua TGW attachment.
# Tach rieng de route table cua no doc lap voi subnet chua NAT.
resource "aws_subnet" "egress_tgw" {
  vpc_id            = aws_vpc.egress.id
  cidr_block        = cidrsubnet(var.egress_vpc_cidr, 12, 32)
  availability_zone = var.azs[0]

  tags = { Name = "${var.project}-egress-tgw", Tier = "tgw" }
}

########################################
# INGRESS VPC - duong vao tu Internet
########################################

resource "aws_vpc" "ingress" {
  count = var.enable_ingress ? 1 : 0

  cidr_block           = var.ingress_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-ingress-vpc" }
}

# ALB bat buoc toi thieu 2 AZ
resource "aws_subnet" "ingress_public" {
  for_each = var.enable_ingress ? { for i, az in var.azs : tostring(i) => az } : {}

  vpc_id                  = aws_vpc.ingress[0].id
  cidr_block              = cidrsubnet(var.ingress_vpc_cidr, 8, tonumber(each.key))
  availability_zone       = each.value
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-ingress-public-${each.key}", Tier = "public" }
}

resource "aws_subnet" "ingress_tgw" {
  count = var.enable_ingress ? 1 : 0

  vpc_id            = aws_vpc.ingress[0].id
  cidr_block        = cidrsubnet(var.ingress_vpc_cidr, 12, 32)
  availability_zone = var.azs[0]

  tags = { Name = "${var.project}-ingress-tgw", Tier = "tgw" }
}

########################################
# SPOKE VPC - workload, KHONG co IGW/NAT
########################################

resource "aws_vpc" "spoke" {
  for_each = var.spokes

  cidr_block           = each.value.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-${each.key}-vpc" }
}

resource "aws_subnet" "spoke_private" {
  for_each = var.spokes

  vpc_id            = aws_vpc.spoke[each.key].id
  cidr_block        = cidrsubnet(each.value.cidr, 8, 1)
  availability_zone = var.azs[0]

  tags = { Name = "${var.project}-${each.key}-private", Tier = "private" }
}

resource "aws_subnet" "spoke_tgw" {
  for_each = var.spokes

  vpc_id            = aws_vpc.spoke[each.key].id
  cidr_block        = cidrsubnet(each.value.cidr, 12, 32)
  availability_zone = var.azs[0]

  tags = { Name = "${var.project}-${each.key}-tgw", Tier = "tgw" }
}

# Route table cua workload: MOI THU ra TGW.
# Khong co route toi IGW hay NAT - do la diem mau chot cua mo hinh.
resource "aws_route_table" "spoke_private" {
  for_each = var.spokes

  vpc_id = aws_vpc.spoke[each.key].id
  tags   = { Name = "${var.project}-${each.key}-private-rt" }
}

resource "aws_route" "spoke_default_to_tgw" {
  for_each = var.spokes

  route_table_id         = aws_route_table.spoke_private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.spoke]
}

resource "aws_route_table_association" "spoke_private" {
  for_each = var.spokes

  subnet_id      = aws_subnet.spoke_private[each.key].id
  route_table_id = aws_route_table.spoke_private[each.key].id
}
