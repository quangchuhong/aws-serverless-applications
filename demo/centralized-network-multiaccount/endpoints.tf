########################################
# Interface endpoint tap trung o NETWORK account,
# chia se cho moi spoke account qua TGW + cross-account PHZ.
########################################

resource "aws_security_group" "endpoints" {
  provider = aws.network
  count    = var.enable_interface_endpoints ? 1 : 0

  name        = "${var.project}-vpce"
  description = "Cho phep spoke account goi vao interface endpoint"
  vpc_id      = aws_vpc.egress.id

  ingress {
    description = "HTTPS tu moi VPC trong org"
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
  provider = aws.network
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : []

  vpc_id            = aws_vpc.egress.id
  service_name      = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type = "Interface"

  subnet_ids         = [aws_subnet.egress_tgw.id]
  security_group_ids = [aws_security_group.endpoints[0].id]

  # Tu quan PHZ de share duoc cho account khac
  private_dns_enabled = false

  # Chi account trong Organization moi goi duoc qua endpoint nay.
  # Day la lop chan exfil du lieu sang account la.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "*"
      Resource  = "*"
      Condition = {
        StringEquals = {
          "aws:PrincipalOrgID" = var.organization_id
        }
      }
    }]
  })

  tags = { Name = "${var.project}-vpce-${each.value}" }
}

########################################
# PHZ o network account
########################################

resource "aws_route53_zone" "endpoint" {
  provider = aws.network
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : []

  name    = "${each.value}.${var.region}.amazonaws.com"
  comment = "${var.project} - PHZ cho VPC endpoint ${each.value}"

  vpc {
    vpc_id = aws_vpc.egress.id
  }

  # BAT BUOC: association tu account khac quan ly bang resource rieng ben duoi.
  # Thieu dong nay, moi lan apply Terraform se go cac association do ra.
  lifecycle {
    ignore_changes = [vpc]
  }

  force_destroy = true
}

resource "aws_route53_record" "endpoint_apex" {
  provider = aws.network
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
  provider = aws.network
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

########################################
# Cross-account PHZ association - hai buoc
#   1. Chu zone (network account) cap phep
#   2. Chu VPC (spoke account) thuc hien association
########################################

resource "aws_route53_vpc_association_authorization" "spoke_a" {
  provider = aws.network
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : []

  zone_id    = aws_route53_zone.endpoint[each.value].zone_id
  vpc_id     = module.spoke_a.vpc_id
  vpc_region = var.region
}

resource "aws_route53_zone_association" "spoke_a" {
  provider = aws.spoke_a
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : []

  zone_id    = aws_route53_vpc_association_authorization.spoke_a[each.value].zone_id
  vpc_id     = aws_route53_vpc_association_authorization.spoke_a[each.value].vpc_id
  vpc_region = var.region
}

resource "aws_route53_vpc_association_authorization" "spoke_b" {
  provider = aws.network
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : []

  zone_id    = aws_route53_zone.endpoint[each.value].zone_id
  vpc_id     = module.spoke_b.vpc_id
  vpc_region = var.region
}

resource "aws_route53_zone_association" "spoke_b" {
  provider = aws.spoke_b
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : []

  zone_id    = aws_route53_vpc_association_authorization.spoke_b[each.value].zone_id
  vpc_id     = aws_route53_vpc_association_authorization.spoke_b[each.value].vpc_id
  vpc_region = var.region
}
