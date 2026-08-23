########################################
# SECURITY VPC
#
# KHONG IGW, KHONG NAT. No khong phai noi den, chi la tram thanh
# tra: nhan tu TGW -> firewall endpoint -> tra lai TGW.
#
# CIDR subnet lay dung theo bang o doc 17 muc 3:
#   firewall  10.1.10.0/28  10.1.11.0/28
#   tgw       10.1.20.0/28  10.1.21.0/28
#   endpoints 10.1.30.0/24  10.1.31.0/24
########################################

resource "aws_vpc" "security" {
  count    = local.fw
  provider = aws.network

  cidr_block           = var.security_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-security-vpc" }
}

resource "aws_subnet" "security_firewall" {
  for_each = local.fw == 1 ? local.azs : {}
  provider = aws.network

  vpc_id            = aws_vpc.security[0].id
  availability_zone = each.key

  # 12 bit them -> /28. Chi so 160 = 10.1.10.0, moi AZ cach nhau 16.
  cidr_block = cidrsubnet(var.security_vpc_cidr, 12, 160 + each.value * 16)

  tags = { Name = "${var.project}-security-firewall-${each.key}", Tier = "firewall" }
}

resource "aws_subnet" "security_tgw" {
  for_each = local.fw == 1 ? local.azs : {}
  provider = aws.network

  vpc_id            = aws_vpc.security[0].id
  availability_zone = each.key

  # Chi so 320 = 10.1.20.0/28
  cidr_block = cidrsubnet(var.security_vpc_cidr, 12, 320 + each.value * 16)

  tags = { Name = "${var.project}-security-tgw-${each.key}", Tier = "tgw" }
}

resource "aws_subnet" "security_endpoints" {
  for_each = local.vpce ? local.azs : {}
  provider = aws.network

  vpc_id            = aws_vpc.security[0].id
  availability_zone = each.key

  # 8 bit them -> /24. Chi so 30 = 10.1.30.0/24
  cidr_block = cidrsubnet(var.security_vpc_cidr, 8, 30 + each.value)

  tags = { Name = "${var.project}-security-endpoints-${each.key}", Tier = "endpoints" }
}

########################################
# TGW attachment
#
# appliance_mode_support = "enable" LA BAT BUOC, va day la thu chi
# lo ra khi chay tu hai AZ tro len.
#
# Khong bat: luong east-west giua hai AZ khac nhau di vao mot
# firewall endpoint o chieu di va MOT ENDPOINT KHAC o chieu ve.
# Firewall stateful chi thay nua phien -> drop.
#
# Trieu chung: ket noi chap chon, hong hay khong tuy vao AZ cua hai
# dau. Rat de nham la loi ung dung.
########################################

resource "aws_ec2_transit_gateway_vpc_attachment" "security" {
  count    = local.fw
  provider = aws.network

  transit_gateway_id = aws_ec2_transit_gateway.hub[0].id
  vpc_id             = aws_vpc.security[0].id
  subnet_ids         = [for z in var.availability_zones : aws_subnet.security_tgw[z].id]

  appliance_mode_support = "enable"

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-tgwa-security" }
}

########################################
# Route table - MOI AZ MOT BANG
#
# Day la khac biet quan trong so voi ban demo mot AZ. Goi tin vao
# subnet tgw cua AZ-a phai di vao firewall endpoint CUA CHINH AZ-a.
# Dung chung mot bang cho ca hai AZ thi mot nua luong di cheo AZ:
# tra them tien truyen cheo AZ, va pha vo tinh doi xung ma firewall
# stateful can.
########################################

resource "aws_route_table" "security_tgw" {
  for_each = local.fw == 1 ? local.azs : {}
  provider = aws.network

  vpc_id = aws_vpc.security[0].id
  tags   = { Name = "${var.project}-sec-tgw-rt-${each.key}" }
}

resource "aws_route" "sec_tgw_to_firewall" {
  for_each = local.fw == 1 ? local.azs : {}
  provider = aws.network

  route_table_id         = aws_route_table.security_tgw[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = local.fw_endpoints[each.key]
}

resource "aws_route_table_association" "security_tgw" {
  for_each = local.fw == 1 ? local.azs : {}
  provider = aws.network

  subnet_id      = aws_subnet.security_tgw[each.key].id
  route_table_id = aws_route_table.security_tgw[each.key].id
}

# Subnet firewall: thanh tra xong thi tra lai TGW. TGW moi la noi
# quyet dinh di dau tiep - egress VPC, spoke khac, hay ingress VPC.
resource "aws_route_table" "security_firewall" {
  for_each = local.fw == 1 ? local.azs : {}
  provider = aws.network

  vpc_id = aws_vpc.security[0].id
  tags   = { Name = "${var.project}-sec-fw-rt-${each.key}" }
}

resource "aws_route" "sec_fw_to_tgw" {
  for_each = local.fw == 1 ? local.azs : {}
  provider = aws.network

  route_table_id         = aws_route_table.security_firewall[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.hub[0].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.security]
}

resource "aws_route_table_association" "security_firewall" {
  for_each = local.fw == 1 ? local.azs : {}
  provider = aws.network

  subnet_id      = aws_subnet.security_firewall[each.key].id
  route_table_id = aws_route_table.security_firewall[each.key].id
}

########################################
# INTERFACE ENDPOINT
#
# Dat o security VPC, khong phai o tung spoke.
#
#   o tung spoke : nhan len theo so spoke, va luong KHONG qua firewall
#   o day        : spoke -> TGW -> firewall -> local route -> endpoint
#
# Duoc thanh tra ma khong ton them chang TGW nao.
########################################

resource "aws_security_group" "endpoints" {
  count    = local.vpce ? 1 : 0
  provider = aws.network

  name        = "${var.project}-vpce"
  description = "Cho phep VPC noi bo goi vao interface endpoint"
  vpc_id      = aws_vpc.security[0].id

  ingress {
    description = "HTTPS tu moi dai noi bo"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.internal_supernet]
  }

  egress {
    description = "Tra loi ve"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-vpce" }
}

resource "aws_route_table" "security_endpoints" {
  count    = local.vpce ? 1 : 0
  provider = aws.network

  vpc_id = aws_vpc.security[0].id
  tags   = { Name = "${var.project}-sec-vpce-rt" }
}

# Chi can duong VE cac dai noi bo. Endpoint khong tu goi ra Internet.
resource "aws_route" "sec_vpce_to_tgw" {
  count    = local.vpce ? 1 : 0
  provider = aws.network

  route_table_id         = aws_route_table.security_endpoints[0].id
  destination_cidr_block = var.internal_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub[0].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.security]
}

resource "aws_route_table_association" "security_endpoints" {
  for_each = local.vpce ? local.azs : {}
  provider = aws.network

  subnet_id      = aws_subnet.security_endpoints[each.key].id
  route_table_id = aws_route_table.security_endpoints[0].id
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.vpce ? toset(var.interface_endpoint_services) : []
  provider = aws.network

  vpc_id            = aws_vpc.security[0].id
  service_name      = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type = "Interface"

  subnet_ids         = [for z in var.availability_zones : aws_subnet.security_endpoints[z].id]
  security_group_ids = [aws_security_group.endpoints[0].id]

  # TAT private DNS cua endpoint va tu quan PHZ - vi PHZ moi chia
  # duoc cho spoke o ACCOUNT KHAC. Bat private_dns_enabled thi ten
  # chi phan giai duoc trong chinh security VPC.
  private_dns_enabled = false

  # Chi principal trong to chuc nay duoc dung endpoint.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "*"
      Resource  = "*"
      Condition = {
        StringEquals = {
          "aws:PrincipalOrgID" = data.aws_organizations_organization.this.id
        }
      }
    }]
  })

  tags = { Name = "${var.project}-vpce-${each.value}" }
}

########################################
# PHZ cho endpoint
#
# Zone tao o account network. Spoke o account KHAC muon dung phai
# duoc lien ket rieng - xem aws_route53_vpc_association_authorization
# trong output next_steps. Terraform khong lam ho buoc do duoc vi
# no can provider cua account spoke.
########################################

resource "aws_route53_zone" "endpoint" {
  for_each = local.vpce ? toset(var.interface_endpoint_services) : []
  provider = aws.network

  name    = "${each.value}.${var.region}.amazonaws.com"
  comment = "${var.project} PHZ cho VPC endpoint ${each.value}"

  vpc {
    vpc_id = aws_vpc.security[0].id
  }

  # Lien ket VPC tu account khac duoc them NGOAI Terraform (qua
  # associate-vpc-with-hosted-zone). Khong bo qua thi moi lan apply
  # Terraform se go chung ra.
  lifecycle {
    ignore_changes = [vpc]
  }
}

resource "aws_route53_record" "endpoint_apex" {
  for_each = local.vpce ? toset(var.interface_endpoint_services) : []
  provider = aws.network

  zone_id = aws_route53_zone.endpoint[each.value].zone_id
  name    = "${each.value}.${var.region}.amazonaws.com"
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.interface[each.value].dns_entry[0]["dns_name"]
    zone_id                = aws_vpc_endpoint.interface[each.value].dns_entry[0]["hosted_zone_id"]
    evaluate_target_health = false
  }
}
