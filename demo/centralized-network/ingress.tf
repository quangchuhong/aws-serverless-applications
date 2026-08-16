########################################
# INGRESS VPC - chi tao khi enable_ingress = true
########################################

resource "aws_internet_gateway" "ingress" {
  count = var.enable_ingress ? 1 : 0

  vpc_id = aws_vpc.ingress[0].id
  tags   = { Name = "${var.project}-ingress-igw" }
}

resource "aws_route_table" "ingress_public" {
  count = var.enable_ingress ? 1 : 0

  vpc_id = aws_vpc.ingress[0].id
  tags   = { Name = "${var.project}-ingress-public-rt" }
}

resource "aws_route" "ingress_public_default" {
  count = var.enable_ingress ? 1 : 0

  route_table_id         = aws_route_table.ingress_public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.ingress[0].id
}

# ALB can voi toi IP target nam trong spoke VPC
resource "aws_route" "ingress_public_to_spokes" {
  count = var.enable_ingress ? 1 : 0

  route_table_id         = aws_route_table.ingress_public[0].id
  destination_cidr_block = var.supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.ingress]
}

resource "aws_route_table_association" "ingress_public" {
  for_each = var.enable_ingress ? aws_subnet.ingress_public : {}

  subnet_id      = each.value.id
  route_table_id = aws_route_table.ingress_public[0].id
}

########################################
# ALB
########################################

resource "aws_security_group" "alb" {
  count = var.enable_ingress ? 1 : 0

  name        = "${var.project}-alb"
  description = "ALB cong khai"
  vpc_id      = aws_vpc.ingress[0].id

  ingress {
    description = "HTTP tu Internet (demo - production dung 443)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Toi target trong spoke"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.supernet]
  }

  tags = { Name = "${var.project}-alb" }
}

resource "aws_lb" "ingress" {
  count = var.enable_ingress ? 1 : 0

  name               = "${var.project}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = [for s in aws_subnet.ingress_public : s.id]
  security_groups    = [aws_security_group.alb[0].id]

  # Demo: PHAI tat de terraform destroy chay duoc
  enable_deletion_protection = false

  tags = { Name = "${var.project}-alb" }
}

# Target group tro vao IP private trong spoke VPC
resource "aws_lb_target_group" "spoke" {
  count = var.enable_ingress ? 1 : 0

  name        = "${var.project}-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.ingress[0].id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
    timeout             = 5
    matcher             = "200"
  }

  deregistration_delay = 10
}

resource "aws_lb_listener" "http" {
  count = var.enable_ingress ? 1 : 0

  load_balancer_arn = aws_lb.ingress[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.spoke[0].arn
  }
}

# Dang ky EC2 test lam target.
# availability_zone = "all" BAT BUOC khi IP target nam ngoai VPC cua ALB.
resource "aws_lb_target_group_attachment" "test" {
  count = var.enable_ingress && var.enable_test_instance ? 1 : 0

  target_group_arn  = aws_lb_target_group.spoke[0].arn
  target_id         = aws_instance.test[0].private_ip
  port              = 80
  availability_zone = "all"
}
