########################################
# SPOKE VPC - workload
# KHONG IGW, KHONG NAT, KHONG IP public
########################################

resource "aws_vpc" "spoke" {
  for_each = local.local_spokes

  cidr_block           = each.value.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-${each.key}-vpc" }
}

# Subnet theo SPOKE x AZ. Khoa dang "app-dev-ap-southeast-1a".
#   private  10.x.0.0/24   10.x.1.0/24   10.x.2.0/24
#   tgw      10.x.20.0/28  10.x.21.0/28  10.x.22.0/28
resource "aws_subnet" "spoke_private" {
  for_each = local.spoke_azs

  vpc_id            = aws_vpc.spoke[each.value.spoke].id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(each.value.cidr, 8, each.value.idx)

  tags = { Name = "${var.project}-${each.key}-private", Tier = "private" }
}

resource "aws_subnet" "spoke_tgw" {
  for_each = local.spoke_azs

  vpc_id            = aws_vpc.spoke[each.value.spoke].id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(each.value.cidr, 12, 320 + each.value.idx * 16)

  tags = { Name = "${var.project}-${each.key}-tgw", Tier = "tgw" }
}

########################################
# Route table cua workload
#
# CHI MOT DONG: 0.0.0.0/0 -> TGW
#
# Dong nay phu TAT CA:
#   - ra Internet
#   - sang spoke khac  <- KHONG can route rieng cho tung cap
#   - toi ingress VPC
#   - toi VPC endpoint trong security VPC
#
# Muon cho phep app-dev goi app-prod? Them RULE FIREWALL,
# khong dong gi vao route. Xem var.east_west_rules.
########################################

resource "aws_route_table" "spoke_private" {
  for_each = local.local_spokes

  vpc_id = aws_vpc.spoke[each.key].id
  tags   = { Name = "${var.project}-${each.key}-private-rt" }
}

resource "aws_route" "spoke_default_to_tgw" {
  for_each = local.local_spokes

  route_table_id         = aws_route_table.spoke_private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.spoke]
}

# MOT bang moi spoke la du: route cua spoke khong phu thuoc AZ
# (0.0.0.0/0 -> TGW o moi AZ). Khac han security/egress, noi bang
# phai tach theo AZ vi tro vao endpoint/NAT khac nhau.
resource "aws_route_table_association" "spoke_private" {
  for_each = local.spoke_azs

  subnet_id      = aws_subnet.spoke_private[each.key].id
  route_table_id = aws_route_table.spoke_private[each.value.spoke].id
}

########################################
# Gateway endpoint - MIEN PHI, tao o MOI VPC.
# Traffic S3/DynamoDB khong roi khoi VPC -> khong qua firewall,
# khong qua TGW, khong tinh tien. Day la don bay giam chi phi
# lon nhat cua ca thiet ke (doc 17 muc 7.4).
########################################

resource "aws_vpc_endpoint" "spoke_s3" {
  for_each = local.local_spokes

  vpc_id            = aws_vpc.spoke[each.key].id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.spoke_private[each.key].id]

  tags = { Name = "${var.project}-${each.key}-s3-gw" }
}

resource "aws_vpc_endpoint" "spoke_dynamodb" {
  for_each = local.local_spokes

  vpc_id            = aws_vpc.spoke[each.key].id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.spoke_private[each.key].id]

  tags = { Name = "${var.project}-${each.key}-ddb-gw" }
}
