########################################
# EC2 kiem chung duong mang
#
# Dat trong spoke dau tien. KHONG co IP public, KHONG co key pair.
# Vao bang SSM Session Manager -> chinh viec ket noi duoc
# da chung minh duong egress tap trung hoat dong.
########################################

locals {
  first_spoke = sort(keys(var.spokes))[0]
}

data "aws_ssm_parameter" "al2023" {
  count = var.enable_test_instance ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_iam_role" "test_instance" {
  count = var.enable_test_instance ? 1 : 0

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

resource "aws_iam_role_policy_attachment" "ssm_core" {
  count = var.enable_test_instance ? 1 : 0

  role       = aws_iam_role.test_instance[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "test_instance" {
  count = var.enable_test_instance ? 1 : 0

  name = "${var.project}-ec2-ssm"
  role = aws_iam_role.test_instance[0].name
}

resource "aws_security_group" "test_instance" {
  count = var.enable_test_instance ? 1 : 0

  name        = "${var.project}-test-ec2"
  description = "EC2 test trong spoke"
  vpc_id      = aws_vpc.spoke[local.first_spoke].id

  # Khong co ingress tu Internet. Chi tu ingress VPC (khi bat ALB).
  ingress {
    description = "HTTP tu ALB o ingress VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.ingress_vpc_cidr]
  }

  # Cho phep ping tu spoke khac de KIEM CHUNG bi TGW chan
  # (SG cho phep, nhung TGW route table khong co duong -> van khong thong)
  ingress {
    description = "ICMP trong demo"
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

  tags = { Name = "${var.project}-test-ec2" }
}

resource "aws_instance" "test" {
  count = var.enable_test_instance ? 1 : 0

  ami                    = data.aws_ssm_parameter.al2023[0].value
  instance_type          = var.test_instance_type
  subnet_id              = aws_subnet.spoke_private[local.first_spoke].id
  vpc_security_group_ids = [aws_security_group.test_instance[0].id]
  iam_instance_profile   = aws_iam_instance_profile.test_instance[0].name

  # Khong bao gio gan IP public
  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required"
  }

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y nginx
    echo "<h1>${local.first_spoke} - qua ingress VPC</h1>" > /usr/share/nginx/html/index.html
    systemctl enable --now nginx
  EOF

  tags = { Name = "${var.project}-test-${local.first_spoke}" }

  # Instance chi len mang duoc khi duong egress da san sang
  depends_on = [
    aws_route.spoke_default_to_tgw,
    aws_route.egress_tgw_default,
    aws_route.egress_public_default,
    aws_route.egress_public_to_spokes,
    aws_ec2_transit_gateway_route.spokes_default,
  ]
}
