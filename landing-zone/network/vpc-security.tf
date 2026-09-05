########################################
# SECURITY VPC - chi tao khi enable_firewall = true
#
# KHONG IGW, KHONG NAT. Chi la tram trung chuyen:
# nhan tu TGW -> firewall endpoint -> tra lai TGW.
########################################

locals {
  fw = var.enable_firewall ? 1 : 0
}

resource "aws_vpc" "security" {
  count = local.fw

  cidr_block           = var.security_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-security-vpc" }
}

# CIDR theo bang o doc 17 muc 3:
#   firewall  10.1.10.0/28  10.1.11.0/28  10.1.12.0/28
#   tgw       10.1.20.0/28  10.1.21.0/28  10.1.22.0/28
#   endpoints 10.1.30.0/24  10.1.31.0/24  10.1.32.0/24

resource "aws_subnet" "security_firewall" {
  for_each = local.fw == 1 ? local.azs : {}

  vpc_id            = aws_vpc.security[0].id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.security_vpc_cidr, 12, 160 + each.value * 16) # 10.1.1<i>.0/28

  tags = { Name = "${var.project}-security-firewall-${each.key}", Tier = "firewall" }
}

resource "aws_subnet" "security_tgw" {
  for_each = local.fw == 1 ? local.azs : {}

  vpc_id            = aws_vpc.security[0].id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.security_vpc_cidr, 12, 320 + each.value * 16) # 10.1.2<i>.0/28

  tags = { Name = "${var.project}-security-tgw-${each.key}", Tier = "tgw" }
}

resource "aws_subnet" "security_endpoints" {
  for_each = var.enable_firewall && var.enable_interface_endpoints ? local.azs : {}

  vpc_id            = aws_vpc.security[0].id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.security_vpc_cidr, 8, 30 + each.value) # 10.1.3<i>.0/24

  tags = { Name = "${var.project}-security-endpoints-${each.key}", Tier = "endpoints" }
}

########################################
# TGW attachment
#
# appliance_mode_support = "enable" LA BAT BUOC.
# Thieu no, luong east-west giua hai AZ khac nhau se di qua
# hai firewall endpoint khac nhau -> firewall stateful chi thay
# nua phien -> drop. Trieu chung: chap chon theo AZ.
#
# Voi 2 AZ tro len, dong nay MOI THUC SU DUOC KIEM CHUNG: bo no ra
# thi luong app-dev(AZ-a) -> app-prod(AZ-b) se dut. O mot AZ thi no
# khong bao gio sai, nen ban mot-AZ khong chung minh duoc gi ve no.
########################################

resource "aws_ec2_transit_gateway_vpc_attachment" "security" {
  count = local.fw

  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.security[0].id
  subnet_ids         = [for z in var.availability_zones : aws_subnet.security_tgw[z].id]

  appliance_mode_support = "enable"

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-tgwa-security" }
}

########################################
# Route table trong security VPC - chi hai bang, moi bang mot dong
########################################

# tgw subnet: MOI AZ MOT BANG, tro vao firewall endpoint CUA CHINH AZ.
#
# Dung chung mot bang la ep mot nua luu luong di cheo AZ vao endpoint
# cua AZ kia - vua ton phi truyen, vua pha tinh doi xung ma firewall
# stateful can de thay du ca hai chieu cua phien.
resource "aws_route_table" "security_tgw" {
  for_each = local.fw == 1 ? local.azs : {}

  vpc_id = aws_vpc.security[0].id
  tags   = { Name = "${var.project}-sec-tgw-rt-${each.key}" }
}

resource "aws_route" "sec_tgw_to_firewall" {
  for_each = local.fw == 1 ? local.azs : {}

  route_table_id         = aws_route_table.security_tgw[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = local.fw_endpoints[each.key]
}

resource "aws_route_table_association" "security_tgw" {
  for_each = local.fw == 1 ? local.azs : {}

  subnet_id      = aws_subnet.security_tgw[each.key].id
  route_table_id = aws_route_table.security_tgw[each.key].id
}

# firewall subnet: thanh tra xong thi tra lai TGW.
# TGW quyet dinh di dau tiep - egress VPC, spoke khac, hay ingress VPC.
resource "aws_route_table" "security_firewall" {
  for_each = local.fw == 1 ? local.azs : {}

  vpc_id = aws_vpc.security[0].id
  tags   = { Name = "${var.project}-sec-fw-rt-${each.key}" }
}

resource "aws_route" "sec_fw_to_tgw" {
  for_each = local.fw == 1 ? local.azs : {}

  route_table_id         = aws_route_table.security_firewall[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.security]
}

resource "aws_route_table_association" "security_firewall" {
  for_each = local.fw == 1 ? local.azs : {}

  subnet_id      = aws_subnet.security_firewall[each.key].id
  route_table_id = aws_route_table.security_firewall[each.key].id
}

########################################
# Interface endpoint DAT TRONG security VPC.
# Traffic tu spoke -> TGW -> firewall -> local route -> endpoint.
# Duoc thanh tra ma khong ton them chang TGW nao.
########################################

resource "aws_security_group" "endpoints" {
  count = var.enable_firewall && var.enable_interface_endpoints ? 1 : 0

  name        = "${var.project}-vpce"
  description = "Cho phep spoke goi vao interface endpoint"
  vpc_id      = aws_vpc.security[0].id

  ingress {
    description = "HTTPS tu moi VPC noi bo"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.internal_supernet]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-vpce" }
}

resource "aws_route_table" "security_endpoints" {
  count = var.enable_firewall && var.enable_interface_endpoints ? 1 : 0

  vpc_id = aws_vpc.security[0].id
  tags   = { Name = "${var.project}-sec-vpce-rt" }
}

resource "aws_route" "sec_vpce_to_tgw" {
  count = var.enable_firewall && var.enable_interface_endpoints ? 1 : 0

  route_table_id         = aws_route_table.security_endpoints[0].id
  destination_cidr_block = var.internal_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.security]
}

# Bang nay dung chung duoc cho moi AZ: chi mot dong route toi TGW,
# khong phu thuoc AZ nao. Khac voi bang tgw/firewall o tren.
resource "aws_route_table_association" "security_endpoints" {
  for_each = var.enable_firewall && var.enable_interface_endpoints ? local.azs : {}

  subnet_id      = aws_subnet.security_endpoints[each.key].id
  route_table_id = aws_route_table.security_endpoints[0].id
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_firewall && var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : []

  vpc_id            = aws_vpc.security[0].id
  service_name      = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type = "Interface"

  # Mot ENI moi AZ. Dat mot AZ thi endpoint chet theo AZ do, va moi
  # spoke mat SSM cung luc - ke ca spoke o AZ khac.
  subnet_ids         = [for z in var.availability_zones : aws_subnet.security_endpoints[z].id]
  security_group_ids = [aws_security_group.endpoints[0].id]

  # Tu quan PHZ de share cho moi spoke
  private_dns_enabled = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "*"
      Resource  = "*"
      Condition = {
        StringEquals = {
          "aws:PrincipalAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })

  tags = { Name = "${var.project}-vpce-${each.value}" }
}

resource "aws_route53_zone" "endpoint" {
  for_each = var.enable_firewall && var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : []

  name          = "${each.value}.${var.region}.amazonaws.com"
  comment       = "${var.project} PHZ cho VPC endpoint ${each.value}"
  force_destroy = var.ephemeral

  vpc {
    vpc_id = aws_vpc.security[0].id
  }

  # Gan thang vao spoke - CHI khi khong dung Route 53 Profile.
  # Dung ca hai duong cho cung mot VPC la thua. Xem dns.tf.
  dynamic "vpc" {
    for_each = var.enable_dns_profile ? {} : local.local_spokes
    content {
      vpc_id = aws_vpc.spoke[vpc.key].id
    }
  }

  # Association them qua Profile hoac tu account khac nam NGOAI state.
  # Khong bo qua thi moi lan apply Terraform se go chung ra.
  lifecycle {
    ignore_changes = [vpc]
  }
}

resource "aws_route53_record" "endpoint_apex" {
  for_each = var.enable_firewall && var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : []

  zone_id = aws_route53_zone.endpoint[each.value].zone_id
  name    = "${each.value}.${var.region}.amazonaws.com"
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.interface[each.value].dns_entry[0]["dns_name"]
    zone_id                = aws_vpc_endpoint.interface[each.value].dns_entry[0]["hosted_zone_id"]
    evaluate_target_health = false
  }
}
