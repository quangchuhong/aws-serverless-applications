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

resource "aws_subnet" "ingress_public" {
  count = local.ing

  vpc_id                  = aws_vpc.ingress[0].id
  cidr_block              = cidrsubnet(var.ingress_vpc_cidr, 8, 0)
  availability_zone       = var.az
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-ingress-public", Tier = "public" }
}

resource "aws_subnet" "ingress_tgw" {
  count = local.ing

  vpc_id            = aws_vpc.ingress[0].id
  cidr_block        = cidrsubnet(var.ingress_vpc_cidr, 12, 32)
  availability_zone = var.az

  tags = { Name = "${var.project}-ingress-tgw", Tier = "tgw" }
}

########################################
# Route table
########################################

resource "aws_route_table" "ingress_public" {
  count = local.ing

  vpc_id = aws_vpc.ingress[0].id
  tags   = { Name = "${var.project}-ingress-public-rt" }
}

resource "aws_route" "ingress_public_default" {
  count = local.ing

  route_table_id         = aws_route_table.ingress_public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.ingress[0].id
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
  count = local.ing

  subnet_id      = aws_subnet.ingress_public[0].id
  route_table_id = aws_route_table.ingress_public[0].id
}

resource "aws_route_table" "ingress_tgw" {
  count = local.ing

  vpc_id = aws_vpc.ingress[0].id
  tags   = { Name = "${var.project}-ingress-tgw-rt" }
}

resource "aws_route_table_association" "ingress_tgw" {
  count = local.ing

  subnet_id      = aws_subnet.ingress_tgw[0].id
  route_table_id = aws_route_table.ingress_tgw[0].id
}

resource "aws_ec2_transit_gateway_vpc_attachment" "ingress" {
  count = local.ing

  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.ingress[0].id
  subnet_ids         = [aws_subnet.ingress_tgw[0].id]

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

resource "aws_lb" "ingress" {
  count = local.ing

  name               = "${var.project}-nlb"
  load_balancer_type = "network"
  internal           = false
  subnets            = [aws_subnet.ingress_public[0].id]

  enable_deletion_protection = false # DEMO: phai tat de destroy duoc

  tags = { Name = "${var.project}-nlb" }
}

locals {
  first_spoke = sort(keys(var.spokes))[0]
}

resource "aws_lb_target_group" "app" {
  count = local.ing

  name        = "${var.project}-tg"
  port        = 80
  protocol    = "TCP"
  target_type = "ip"
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
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[0].arn
  }
}

# availability_zone = "all" BAT BUOC khi IP target nam ngoai VPC cua LB
resource "aws_lb_target_group_attachment" "app" {
  count = var.enable_ingress && var.enable_test_instances ? 1 : 0

  target_group_arn  = aws_lb_target_group.app[0].arn
  target_id         = aws_instance.test[local.first_spoke].private_ip
  port              = 80
  availability_zone = "all"
}
