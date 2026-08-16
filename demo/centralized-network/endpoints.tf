########################################
# GATEWAY ENDPOINT - MIEN PHI, tao o MOI VPC
#
# Gateway endpoint la route table entry, khong phai ENI.
# Khong chia se duoc qua TGW -> bat buoc tao o tung VPC.
# Khong ton dong nao -> khong co ly do bo qua.
########################################

resource "aws_vpc_endpoint" "s3_gateway_spoke" {
  for_each = var.spokes

  vpc_id            = aws_vpc.spoke[each.key].id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.spoke_private[each.key].id]

  tags = { Name = "${var.project}-${each.key}-s3-gw" }
}

resource "aws_vpc_endpoint" "dynamodb_gateway_spoke" {
  for_each = var.spokes

  vpc_id            = aws_vpc.spoke[each.key].id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.spoke_private[each.key].id]

  tags = { Name = "${var.project}-${each.key}-ddb-gw" }
}

########################################
# INTERFACE ENDPOINT tap trung
#
# Dat trong egress VPC, chia se cho moi spoke qua TGW.
# Chi tao khi enable_interface_endpoints = true (~$0.01/gio moi cai).
########################################

resource "aws_security_group" "endpoints" {
  count = var.enable_interface_endpoints ? 1 : 0

  name        = "${var.project}-vpce"
  description = "Cho phep spoke goi vao interface endpoint"
  vpc_id      = aws_vpc.egress.id

  ingress {
    description = "HTTPS tu moi VPC trong demo"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.supernet]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-vpce" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : []

  vpc_id            = aws_vpc.egress.id
  service_name      = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type = "Interface"

  subnet_ids         = [aws_subnet.egress_tgw.id]
  security_group_ids = [aws_security_group.endpoints[0].id]

  # TAT private DNS: ta tu quan PHZ de share cho moi spoke.
  # Neu de true, PHZ chi gan vao egress VPC -> spoke khong dung duoc.
  private_dns_enabled = false

  # Chi principal trong account nay goi duoc.
  # Production: doi sang dieu kien aws:PrincipalOrgID.
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

########################################
# Private Hosted Zone cho tung endpoint
########################################

resource "aws_route53_zone" "endpoint" {
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : []

  name    = "${each.value}.${var.region}.amazonaws.com"
  comment = "${var.project} - PHZ cho VPC endpoint ${each.value}"

  # Gan vao egress VPC va TAT CA spoke VPC
  vpc {
    vpc_id = aws_vpc.egress.id
  }

  dynamic "vpc" {
    for_each = var.spokes
    content {
      vpc_id = aws_vpc.spoke[vpc.key].id
    }
  }

  # Demo o mot account nen khai bao vpc truc tiep duoc.
  # Multi-account phai dung aws_route53_vpc_association_authorization
  # + ignore_changes = [vpc]  (xem doc 12).

  force_destroy = true
}

resource "aws_route53_record" "endpoint_apex" {
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : []

  zone_id = aws_route53_zone.endpoint[each.value].zone_id
  name    = "${each.value}.${var.region}.amazonaws.com"
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.interface[each.value].dns_entry[0]["dns_name"]
    zone_id                = aws_vpc_endpoint.interface[each.value].dns_entry[0]["hosted_zone_id"]
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "endpoint_wildcard" {
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : []

  zone_id = aws_route53_zone.endpoint[each.value].zone_id
  name    = "*.${each.value}.${var.region}.amazonaws.com"
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.interface[each.value].dns_entry[0]["dns_name"]
    zone_id                = aws_vpc_endpoint.interface[each.value].dns_entry[0]["hosted_zone_id"]
    evaluate_target_health = false
  }
}
