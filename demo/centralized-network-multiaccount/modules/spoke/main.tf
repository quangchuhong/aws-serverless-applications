terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

########################################
# Spoke VPC trong account workload.
# KHONG co IGW, KHONG co NAT, KHONG co IP public.
########################################

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-${var.name}-vpc" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr, 8, 1)
  availability_zone = var.az

  tags = { Name = "${var.project}-${var.name}-private", Tier = "private" }
}

resource "aws_subnet" "tgw" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr, 12, 32)
  availability_zone = var.az

  tags = { Name = "${var.project}-${var.name}-tgw", Tier = "tgw" }
}

########################################
# Attachment vao TGW DUOC SHARE tu network account.
#
# Day la khac biet chinh so voi ban single-account:
# attachment tao o account SPOKE, tro toi TGW cua account KHAC.
# Chay duoc la nho RAM share o network.tf.
########################################

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.transit_gateway_id
  vpc_id             = aws_vpc.this.id
  subnet_ids         = [aws_subnet.tgw.id]

  # Account so huu VPC khong duoc phep tu chon route table cua TGW.
  # Viec do do account so huu TGW lam (xem network.tf).
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-tgwa-${var.name}" }
}

########################################
# Route table: moi thu ra TGW
########################################

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project}-${var.name}-private-rt" }
}

resource "aws_route" "default_to_tgw" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

########################################
# Gateway endpoint - MIEN PHI, phai tao o TUNG VPC
########################################

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.project}-${var.name}-s3-gw" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.project}-${var.name}-ddb-gw" }
}

########################################
# EC2 kiem chung (tuy chon)
########################################

data "aws_ssm_parameter" "al2023" {
  count = var.enable_test_instance ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_iam_role" "ec2" {
  count = var.enable_test_instance ? 1 : 0
  name  = "${var.project}-${var.name}-ec2-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count      = var.enable_test_instance ? 1 : 0
  role       = aws_iam_role.ec2[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  count = var.enable_test_instance ? 1 : 0
  name  = "${var.project}-${var.name}-ec2-ssm"
  role  = aws_iam_role.ec2[0].name
}

resource "aws_security_group" "ec2" {
  count = var.enable_test_instance ? 1 : 0

  name        = "${var.project}-${var.name}-ec2"
  description = "EC2 test trong spoke"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "ICMP - de kiem chung cach ly spoke-to-spoke"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.supernet]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-${var.name}-ec2" }
}

resource "aws_instance" "test" {
  count = var.enable_test_instance ? 1 : 0

  ami                         = data.aws_ssm_parameter.al2023[0].value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.ec2[0].id]
  iam_instance_profile        = aws_iam_instance_profile.ec2[0].name
  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = "${var.project}-test-${var.name}" }

  depends_on = [aws_route.default_to_tgw]
}
