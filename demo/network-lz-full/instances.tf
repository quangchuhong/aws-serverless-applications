########################################
# EC2 kiem chung - moi spoke mot cai
#
# KHONG IP public, KHONG key pair. Vao bang SSM Session Manager.
# Chinh viec vao duoc da chung minh duong egress tap trung hoat dong,
# vi SSM agent phai ra Internet qua egress VPC moi dang ky duoc.
########################################

data "aws_ssm_parameter" "al2023" {
  count = var.enable_test_instances ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_iam_role" "ec2" {
  count = var.enable_test_instances ? 1 : 0

  name = "${var.project}-ec2-ssm"

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
  count = var.enable_test_instances ? 1 : 0

  role       = aws_iam_role.ec2[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  count = var.enable_test_instances ? 1 : 0

  name = "${var.project}-ec2-ssm"
  role = aws_iam_role.ec2[0].name
}

########################################
# Security group
#
# LOP THU BA cua kiem soat, ngoai route va firewall rule.
# Ca ba deu phai cho phep thi luong moi thong.
########################################

resource "aws_security_group" "test" {
  for_each = var.enable_test_instances ? var.spokes : {}

  name        = "${var.project}-${each.key}-ec2"
  description = "EC2 test trong ${each.key}"
  vpc_id      = aws_vpc.spoke[each.key].id

  ingress {
    description = "HTTP tu NLB o ingress VPC va tu spoke khac"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.internal_supernet]
  }

  # Mo SSH o SG de CHUNG MINH: SG cho phep nhung firewall van chan,
  # vi khong co rule east-west nao cho port 22.
  ingress {
    description = "SSH - mo o SG nhung firewall se chan"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.internal_supernet]
  }

  ingress {
    description = "ICMP de troubleshoot"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.internal_supernet]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-${each.key}-ec2" }
}

resource "aws_instance" "test" {
  for_each = var.enable_test_instances ? var.spokes : {}

  ami                         = data.aws_ssm_parameter.al2023[0].value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.spoke_private[each.key].id
  vpc_security_group_ids      = [aws_security_group.test[each.key].id]
  iam_instance_profile        = aws_iam_instance_profile.ec2[0].name
  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required"
  }

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y nginx nmap-ncat bind-utils
    echo "<h1>${each.key}</h1><p>VPC ${each.value.cidr}</p>" > /usr/share/nginx/html/index.html
    systemctl enable --now nginx
  EOF

  tags = { Name = "${var.project}-${each.key}" }

  # Instance chi len mang duoc khi toan bo duong egress da san sang
  depends_on = [
    aws_route.spoke_default_to_tgw,
    aws_route.egress_tgw_default,
    aws_route.egress_public_default,
    aws_route.egress_public_to_internal,
    aws_ec2_transit_gateway_route.spokes_default,
  ]
}
