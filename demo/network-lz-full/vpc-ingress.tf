########################################
# INGRESS VPC
#
# THIEU SO VOI THIET KE THAT (doc 14):
#   - KHONG co GWLB + Palo Alto
#   - KHONG co F5 BIG-IP
#   - KHONG co CDN
#
# Demo nay chi co NLB -> thang xuong app trong spoke, de kiem chung
# duong dinh tuyen ingress -> TGW -> firewall -> spoke va duong ve.
# PA/F5 chen vao giua NLB va TGW sau, phan dinh tuyen giu nguyen.
########################################

locals {
  ing = var.enable_ingress ? 1 : 0
}

resource "aws_vpc" "ingress" {
  count = local.ing

  cidr_block           = var.ingress_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-ingress-vpc" }
}

resource "aws_internet_gateway" "ingress" {
  count = local.ing

  vpc_id = aws_vpc.ingress[0].id
  tags   = { Name = "${var.project}-ingress-igw" }
}

# CIDR theo bang o doc 17 muc 3:
#   public  10.0.0.0/24   10.0.1.0/24   10.0.2.0/24
#   tgw     10.0.40.0/28  10.0.41.0/28  10.0.42.0/28
#
# tgw bat dau tu .40 de chua cho gwlbe (.10), appliance (.20) va
# f5 (.30) o appliances.tf - dung ban do cua doc 17.
resource "aws_subnet" "ingress_public" {
  for_each = local.ing == 1 ? local.azs : {}

  vpc_id                  = aws_vpc.ingress[0].id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.ingress_vpc_cidr, 8, each.value)
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-ingress-public-${each.key}", Tier = "public" }
}

resource "aws_subnet" "ingress_tgw" {
  for_each = local.ing == 1 ? local.azs : {}

  vpc_id            = aws_vpc.ingress[0].id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.ingress_vpc_cidr, 12, 640 + each.value * 16)

  tags = { Name = "${var.project}-ingress-tgw-${each.key}", Tier = "tgw" }
}

########################################
# Route table
########################################

resource "aws_route_table" "ingress_public" {
  count = local.ing

  vpc_id = aws_vpc.ingress[0].id
  tags   = { Name = "${var.project}-ingress-public-rt" }
}

# Khong co appliance: ra thang IGW.
# Co appliance: ra GWLBe de goi TRA VE cung bi Palo Alto thanh tra.
# De thang IGW khi da co GWLB la loi lam luong bat doi xung -> PA drop.
resource "aws_route" "ingress_public_default" {
  count = local.ing

  route_table_id         = aws_route_table.ingress_public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = local.app_on > 0 ? null : aws_internet_gateway.ingress[0].id
  vpc_endpoint_id        = local.app_on > 0 ? aws_vpc_endpoint.gwlbe[0].id : null
}

# NLB can voi toi target la IP private trong spoke VPC
resource "aws_route" "ingress_public_to_internal" {
  count = local.ing

  route_table_id         = aws_route_table.ingress_public[0].id
  destination_cidr_block = var.internal_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.ingress]
}

resource "aws_route_table_association" "ingress_public" {
  for_each = local.ing == 1 ? local.azs : {}

  subnet_id      = aws_subnet.ingress_public[each.key].id
  route_table_id = aws_route_table.ingress_public[0].id
}

resource "aws_route_table" "ingress_tgw" {
  count = local.ing

  vpc_id = aws_vpc.ingress[0].id
  tags   = { Name = "${var.project}-ingress-tgw-rt" }
}

resource "aws_route_table_association" "ingress_tgw" {
  for_each = local.ing == 1 ? local.azs : {}

  subnet_id      = aws_subnet.ingress_tgw[each.key].id
  route_table_id = aws_route_table.ingress_tgw[0].id
}

resource "aws_ec2_transit_gateway_vpc_attachment" "ingress" {
  count = local.ing

  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.ingress[0].id
  subnet_ids         = [for z in var.availability_zones : aws_subnet.ingress_tgw[z].id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-tgwa-ingress" }
}

########################################
# NLB
#
# Trong thiet ke that, NLB dung TRUOC F5 (doc 14 muc 7).
# O day NLB tro thang vao app de kiem chung dinh tuyen.
########################################

########################################
# Security group cua NLB - khoa origin
#
# CDN TAT : cho phep 80 tu moi noi (goi thang vao NLB de test)
# CDN BAT : CHI cho phep prefix list cua CloudFront
#           -> goi thang vao NLB se bi chan, phai di qua CDN
#
# Doi enable_cdn chi doi RULE, khong tao lai NLB.
########################################

data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
  count = local.cdn
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "nlb" {
  count = local.ing

  name        = "${var.project}-nlb"
  description = "NLB ingress"
  vpc_id      = aws_vpc.ingress[0].id

  egress {
    description = "Toi app trong spoke qua TGW"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.internal_supernet]
  }

  tags = { Name = "${var.project}-nlb" }
}

# Khong bat CDN: NLB tu no la duong vao, khong co gi truoc no.
#
# Mac dinh 0.0.0.0/0 - dung cho demo, va CHI dung cho demo. Do la mot
# cong HTTP cong khai: khong CDN, khong WAF, khong TLS.
#
# Giu bo nay lam mang that thi siet ingress_allowed_cidrs lai, hoac bat
# enable_cdn = true de chi CloudFront vao duoc. Co check block ben duoi
# canh bao khi ephemeral = false ma van de mo.
resource "aws_security_group_rule" "nlb_open" {
  count = var.enable_ingress && !var.enable_cdn ? 1 : 0

  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = var.ingress_allowed_cidrs
  security_group_id = aws_security_group.nlb[0].id
  description       = "HTTP tu ${join(", ", var.ingress_allowed_cidrs)} (chua bat CDN)"
}

check "ingress_not_open_to_world_in_prod" {
  assert {
    condition = (
      var.ephemeral
      || !var.enable_ingress
      || var.enable_cdn
      || !contains(var.ingress_allowed_cidrs, "0.0.0.0/0")
    )
    error_message = "ephemeral = false (ha tang thuong tru) nhung NLB dang mo cong 80 cho 0.0.0.0/0, khong CDN, khong WAF, khong TLS. Siet ingress_allowed_cidrs, hoac bat enable_cdn = true de chi CloudFront vao duoc."
  }
}

# Bat CDN: CHI CloudFront. Day la lop chan di vong qua CDN.
resource "aws_security_group_rule" "nlb_cdn_only" {
  count = local.cdn

  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.cloudfront_origin[0].id]
  security_group_id = aws_security_group.nlb[0].id
  description       = "CHI CloudFront duoc goi vao origin"
}

resource "aws_lb" "ingress" {
  count = local.ing

  name               = "${var.project}-nlb"
  load_balancer_type = "network"
  internal           = false
  # NLB co mot node o MOI AZ duoc liet ke. Mot AZ thi ca duong vao
  # chet theo AZ do.
  subnets         = [for z in var.availability_zones : aws_subnet.ingress_public[z].id]
  security_groups = [aws_security_group.nlb[0].id]

  # ephemeral = true  -> tat, de destroy chay tron
  # ephemeral = false -> bat, vi day la duong vao duy nhat cua ung dung
  enable_deletion_protection = !var.ephemeral

  tags = { Name = "${var.project}-nlb" }
}

locals {
  first_spoke = sort(keys(local.local_spokes))[0]
}

# Khong co appliance: target la IP cua app trong spoke (qua TGW)
# Co appliance:       target la instance F5, F5 moi goi xuong app
resource "aws_lb_target_group" "app" {
  count = local.ing

  name        = "${var.project}-tg"
  port        = var.nlb_listener_port
  protocol    = "TCP"
  target_type = local.app_on > 0 ? "instance" : "ip"
  vpc_id      = aws_vpc.ingress[0].id

  # QUAN TRONG: target nam O VPC KHAC, di qua TGW.
  # Neu bat preserve_client_ip, app se phai tra loi thang ve IP public
  # cua client -> goi di qua firewall/NAT -> luong bat doi xung -> hong.
  # Tat di, app thay IP cua NLB va tra loi ve dung do.
  preserve_client_ip = false

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  deregistration_delay = 10
}

resource "aws_lb_listener" "http" {
  count = local.ing

  load_balancer_arn = aws_lb.ingress[0].arn
  port              = var.nlb_listener_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[0].arn
  }
}

# KHONG co appliance: NLB tro thang vao app trong spoke.
# availability_zone = "all" BAT BUOC khi IP target nam ngoai VPC cua LB.
resource "aws_lb_target_group_attachment" "app_direct" {
  count = var.enable_ingress && var.enable_test_instances && !var.enable_appliances ? 1 : 0

  target_group_arn  = aws_lb_target_group.app[0].arn
  target_id         = aws_instance.test[local.first_spoke].private_ip
  port              = var.nlb_listener_port
  availability_zone = "all"
}

# CO appliance: NLB tro vao F5, F5 moi goi xuong app.
resource "aws_lb_target_group_attachment" "app_via_f5" {
  count = local.app_on

  target_group_arn = aws_lb_target_group.app[0].arn
  target_id        = aws_instance.f5[0].id
  port             = var.nlb_listener_port
}
