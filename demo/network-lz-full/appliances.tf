########################################
# PALO ALTO (qua GWLB) + F5 BIG-IP
#
# enable_appliances = false (MAC DINH)
#   -> khong tao gi. Luong: IGW -> NLB -> app trong spoke.
#
# enable_appliances = true
#   -> IGW -> GWLBe -> Palo Alto -> NLB -> F5 -> TGW -> app
#
# Code viet san de:
#   1. terraform plan kiem chung duoc cu phap va tham chieu
#   2. Khi co license chi can bat bien len, khong phai viet lai
#
# CHUA APPLY DUOC neu chua subscribe AMI tren Marketplace.
# Muon plan ma chua subscribe: dat pa_ami_id / f5_ami_id bang
# mot AMI bat ky (vd AMI Amazon Linux) de bo qua data source.
########################################

locals {
  app_on = var.enable_appliances && var.enable_ingress ? 1 : 0
}

########################################
# Subnet - theo bang chuan doc 17 muc 3
########################################

resource "aws_subnet" "ingress_gwlbe" {
  count = local.app_on

  vpc_id            = aws_vpc.ingress[0].id
  cidr_block        = "10.0.10.0/28"
  availability_zone = local.primary_az

  tags = { Name = "${var.project}-ingress-gwlbe", Tier = "gwlbe" }
}

resource "aws_subnet" "ingress_appliance" {
  count = local.app_on

  vpc_id            = aws_vpc.ingress[0].id
  cidr_block        = "10.0.20.0/24"
  availability_zone = local.primary_az

  tags = { Name = "${var.project}-ingress-appliance", Tier = "appliance" }
}

resource "aws_subnet" "ingress_f5" {
  count = local.app_on

  vpc_id            = aws_vpc.ingress[0].id
  cidr_block        = "10.0.30.0/24"
  availability_zone = local.primary_az

  tags = { Name = "${var.project}-ingress-f5", Tier = "f5" }
}

resource "aws_subnet" "ingress_mgmt" {
  count = local.app_on

  vpc_id            = aws_vpc.ingress[0].id
  cidr_block        = "10.0.50.0/24"
  availability_zone = local.primary_az

  tags = { Name = "${var.project}-ingress-mgmt", Tier = "mgmt" }
}

########################################
# GATEWAY LOAD BALANCER + PALO ALTO
########################################

resource "aws_lb" "gwlb" {
  count = local.app_on

  name               = "${var.project}-gwlb"
  load_balancer_type = "gateway"
  subnets            = [aws_subnet.ingress_appliance[0].id]

  enable_cross_zone_load_balancing = true

  tags = { Name = "${var.project}-gwlb" }
}

resource "aws_lb_target_group" "palo_alto" {
  count = local.app_on

  name        = "${var.project}-pa"
  port        = 6081
  protocol    = "GENEVE"
  vpc_id      = aws_vpc.ingress[0].id
  target_type = "instance"

  health_check {
    protocol            = var.pa_health_check_protocol
    port                = var.pa_health_check_port
    interval            = 10
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  # Giu phien bam vao cung mot instance PA - firewall stateful bat buoc
  stickiness {
    type    = "source_ip_dest_ip_proto"
    enabled = true
  }
}

resource "aws_lb_listener" "gwlb" {
  count = local.app_on

  load_balancer_arn = aws_lb.gwlb[0].arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.palo_alto[0].arn
  }
}

resource "aws_vpc_endpoint_service" "gwlb" {
  count = local.app_on

  acceptance_required        = false
  gateway_load_balancer_arns = [aws_lb.gwlb[0].arn]

  tags = { Name = "${var.project}-gwlb-svc" }
}

resource "aws_vpc_endpoint" "gwlbe" {
  count = local.app_on

  vpc_id            = aws_vpc.ingress[0].id
  service_name      = aws_vpc_endpoint_service.gwlb[0].service_name
  vpc_endpoint_type = "GatewayLoadBalancer"
  subnet_ids        = [aws_subnet.ingress_gwlbe[0].id]

  tags = { Name = "${var.project}-gwlbe" }
}

########################################
# Instance Palo Alto
########################################

data "aws_ami" "palo_alto" {
  count = local.app_on > 0 && var.pa_ami_id == "" ? 1 : 0

  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "name"
    values = [var.pa_ami_name_pattern]
  }
}

resource "aws_security_group" "palo_alto" {
  count = local.app_on

  name        = "${var.project}-pa"
  description = "Palo Alto VM-Series, target cua GWLB"
  vpc_id      = aws_vpc.ingress[0].id

  ingress {
    description = "GENEVE tu GWLB"
    from_port   = 6081
    to_port     = 6081
    protocol    = "udp"
    cidr_blocks = [var.ingress_vpc_cidr]
  }

  ingress {
    description = "Health check tu GWLB"
    from_port   = var.pa_health_check_port
    to_port     = var.pa_health_check_port
    protocol    = "tcp"
    cidr_blocks = [var.ingress_vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-pa" }
}

########################################
# BOOTSTRAP PALO ALTO
#
# VM-Series doc cau hinh khoi dau tu MOT BUCKET S3 co dung bon thu
# muc: config/, license/, software/, content/. Thieu bat cu thu muc
# nao thi PAN-OS bo qua CA goi bootstrap - va no bo qua IM LANG:
# thiet bi len binh thuong voi cau hinh goc, khong interface, khong
# zone, khong policy.
#
# Trieu chung: GWLB bao target unhealthy mai mai, va khong co gi noi
# tai sao. Do la ly do ba thu muc rong van phai duoc tao ra.
#
# S3 khong co thu muc that - mot object rong ket thuc bang "/" la du
# de PAN-OS thay tien to do khi liet ke.
########################################

resource "aws_s3_bucket" "pa_bootstrap" {
  count = local.app_on

  bucket        = "${var.project}-pa-bootstrap-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${var.project}-pa-bootstrap" }
}

resource "aws_s3_bucket_public_access_block" "pa_bootstrap" {
  count = local.app_on

  bucket = aws_s3_bucket.pa_bootstrap[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pa_bootstrap" {
  count = local.app_on

  bucket = aws_s3_bucket.pa_bootstrap[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Ba thu muc RONG. Khong co chung thi ca goi bootstrap bi bo qua.
resource "aws_s3_object" "pa_bootstrap_dirs" {
  for_each = local.app_on > 0 ? toset(["license/", "software/", "content/"]) : toset([])

  bucket  = aws_s3_bucket.pa_bootstrap[0].id
  key     = each.value
  content = ""
}

resource "aws_s3_object" "pa_init_cfg" {
  count = local.app_on

  bucket = aws_s3_bucket.pa_bootstrap[0].id
  key    = "config/init-cfg.txt"

  # mgmt-interface-swap: doi eth0 va eth1.
  #
  # GWLB gui GENEVE toi ENI CHINH cua instance. Mac dinh PAN-OS lay
  # eth0 lam giao dien QUAN TRI, nen khong doi thi luu luong can quet
  # den mot cong khong xu ly duoc goi tin, va giao dien du lieu thi
  # nam o ENI phu ma GWLB khong bao gio gui toi.
  #
  # Doi lai thi eth0 thanh du lieu (ethernet1/1) va eth1 thanh quan
  # tri - dung thu tu ma phan dinh tuyen va security group ben duoi
  # gia dinh.
  #
  # aws-gwlb-inspect: bat ket cuoi GENEVE. Thieu no thi PAN-OS nhan
  # duoc goi GENEVE va khong biet lam gi voi chung.
  content = templatefile("${path.module}/templates/pa-init-cfg.txt.tftpl", {
    hostname           = "${var.project}-pa"
    dns_primary        = "169.254.169.253"
    dns_secondary      = "8.8.8.8"
    op_command_modes   = "mgmt-interface-swap"
    plugin_op_commands = "aws-gwlb-inspect:enable"
  })
}

resource "aws_s3_object" "pa_bootstrap_xml" {
  count = local.app_on

  bucket = aws_s3_bucket.pa_bootstrap[0].id
  key    = "config/bootstrap.xml"

  content = templatefile("${path.module}/templates/pa-bootstrap.xml.tftpl", {
    panos_version          = var.pa_panos_version
    hostname               = "${var.project}-pa"
    dns_primary            = "169.254.169.253"
    dns_secondary          = "8.8.8.8"
    permitted_ips          = var.pa_mgmt_allowed_cidrs
    zone_name              = var.pa_zone_name
    allowed_applications   = var.pa_allowed_applications
    security_profile_group = var.pa_security_profile_group
    default_action         = var.pa_default_action
  })
}

########################################
# Quyen doc bucket bootstrap
#
# CHI doc, CHI bucket nay. VM-Series khong can gi khac tu AWS.
########################################

resource "aws_iam_role" "pa" {
  count = local.app_on

  name = "${var.project}-pa-bootstrap"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "pa" {
  count = local.app_on

  name = "bootstrap-read"
  role = aws_iam_role.pa[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ListBucket la quyen tren CHINH bucket, khong phai tren
        # object - va PAN-OS can no de tim bon thu muc. Thieu no thi
        # GetObject van chay ma bootstrap van bi bo qua.
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.pa_bootstrap[0].arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.pa_bootstrap[0].arn}/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "pa" {
  count = local.app_on

  name = "${var.project}-pa-bootstrap"
  role = aws_iam_role.pa[0].name
}

########################################
# Security group cho giao dien QUAN TRI
#
# Tach khoi security group cua giao dien du lieu. Hai giao dien phuc
# vu hai muc dich va chiu hai muc rui ro khac nhau; dung chung mot
# security group nghia la noi long cho cai nay la noi long cho ca cai
# kia.
########################################

resource "aws_security_group" "pa_mgmt" {
  count = local.app_on

  name        = "${var.project}-pa-mgmt"
  description = "Giao dien quan tri Palo Alto - chi tu dai quan tri"
  vpc_id      = aws_vpc.ingress[0].id

  tags = { Name = "${var.project}-pa-mgmt" }
}

resource "aws_vpc_security_group_ingress_rule" "pa_mgmt_https" {
  for_each = local.app_on > 0 ? toset(var.pa_mgmt_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.pa_mgmt[0].id
  description       = "Giao dien web quan tri"

  cidr_ipv4   = each.value
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "pa_mgmt_ssh" {
  for_each = local.app_on > 0 ? toset(var.pa_mgmt_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.pa_mgmt[0].id
  description       = "SSH - dang nhap lan dau bang key pair"

  cidr_ipv4   = each.value
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "pa_mgmt" {
  count = local.app_on

  security_group_id = aws_security_group.pa_mgmt[0].id
  description       = "Cap nhat chu ky, license, bootstrap"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

########################################
# Instance Palo Alto
#
# HAI GIAO DIEN, va thu tu cua chung quan trong:
#
#   eth0  subnet appliance  <- GWLB gui GENEVE toi day
#   eth1  subnet mgmt       <- nguoi quan tri vao day
#
# Cong voi mgmt-interface-swap trong init-cfg.txt, PAN-OS doc eth0
# thanh ethernet1/1 (du lieu) va eth1 thanh giao dien quan tri.
#
# Mot giao dien thoi thi KHONG chay: GWLB gui toi ENI chinh, va neu
# ENI chinh la giao dien quan tri thi goi tin can quet khong bao gio
# toi mat phang du lieu.
########################################

resource "aws_network_interface" "pa_mgmt" {
  count = local.app_on

  subnet_id       = aws_subnet.ingress_mgmt[0].id
  security_groups = [aws_security_group.pa_mgmt[0].id]

  description = "Giao dien quan tri Palo Alto (eth1 sau khi swap)"
  tags        = { Name = "${var.project}-pa-mgmt" }
}

resource "aws_instance" "palo_alto" {
  count = local.app_on

  ami           = var.pa_ami_id != "" ? var.pa_ami_id : one(data.aws_ami.palo_alto[*].id)
  instance_type = var.pa_instance_type

  subnet_id              = aws_subnet.ingress_appliance[0].id
  vpc_security_group_ids = [aws_security_group.palo_alto[0].id]
  iam_instance_profile   = aws_iam_instance_profile.pa[0].name

  # Rong = khong ai vao duoc thiet bi. Xem mo ta bien pa_key_name.
  key_name = var.pa_key_name != "" ? var.pa_key_name : null

  # BAT BUOC: firewall phai chuyen tiep goi khong phai cua minh.
  # Thieu dong nay thi EC2 vut bo moi goi va PA khong nhan duoc gi.
  source_dest_check = false

  # KHONG phai mot script.
  #
  # VM-Series doc user_data nhu mot chuoi khoa=gia tri, khong phai
  # shell. Dung dong nay chi tro toi bucket; toan bo cau hinh nam
  # trong config/init-cfg.txt va config/bootstrap.xml o do.
  #
  # Ghi mot script bash vao day thi PAN-OS bo qua, va thiet bi len
  # voi cau hinh goc - im lang, khong loi.
  user_data = "vmseries-bootstrap-aws-s3bucket=${aws_s3_bucket.pa_bootstrap[0].id}"

  root_block_device {
    volume_size = 60
    volume_type = "gp3"
    encrypted   = true
  }

  # Bootstrap doc S3 LUC BOOT. Object phai co truoc instance, neu
  # khong thiet bi len voi cau hinh goc va chi mot lan thay instance
  # moi sua duoc.
  depends_on = [
    aws_s3_object.pa_init_cfg,
    aws_s3_object.pa_bootstrap_xml,
    aws_s3_object.pa_bootstrap_dirs,
  ]

  tags = { Name = "${var.project}-pa" }
}

resource "aws_network_interface_attachment" "pa_mgmt" {
  count = local.app_on

  instance_id          = aws_instance.palo_alto[0].id
  network_interface_id = aws_network_interface.pa_mgmt[0].id
  device_index         = 1
}

resource "aws_lb_target_group_attachment" "palo_alto" {
  count = local.app_on

  target_group_arn = aws_lb_target_group.palo_alto[0].arn
  target_id        = aws_instance.palo_alto[0].id
}

########################################
# F5 BIG-IP
########################################

data "aws_ami" "f5" {
  count = local.app_on > 0 && var.f5_ami_id == "" ? 1 : 0

  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "name"
    values = [var.f5_ami_name_pattern]
  }
}

# Mat khau admin - KHONG hardcode, Runtime Init doc tu Secrets Manager
resource "random_password" "f5_admin" {
  count            = local.app_on
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}"
}

resource "aws_secretsmanager_secret" "f5_admin" {
  count = local.app_on

  name                    = "${var.project}-f5-admin"
  recovery_window_in_days = 0 # DEMO: xoa ngay, khong cho 7-30 ngay

  tags = { Name = "${var.project}-f5-admin" }
}

resource "aws_secretsmanager_secret_version" "f5_admin" {
  count = local.app_on

  secret_id     = aws_secretsmanager_secret.f5_admin[0].id
  secret_string = random_password.f5_admin[0].result
}

# S3 chua AS3 + WAF policy. De o day thay vi inline de sua chinh sach
# khong phai thay instance.
resource "aws_s3_bucket" "f5_config" {
  count = local.app_on

  bucket        = "${var.project}-f5-config-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.ephemeral

  tags = { Name = "${var.project}-f5-config" }
}

resource "aws_s3_bucket_public_access_block" "f5_config" {
  count = local.app_on

  bucket                  = aws_s3_bucket.f5_config[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "f5" {
  count = local.app_on

  name = "${var.project}-f5"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "f5" {
  count = local.app_on

  name = "f5-bootstrap"
  role = aws_iam_role.f5[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.f5_config[0].arn, "${aws_s3_bucket.f5_config[0].arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.f5_admin[0].arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "f5" {
  count = local.app_on

  name = "${var.project}-f5"
  role = aws_iam_role.f5[0].name
}

resource "aws_security_group" "f5" {
  count = local.app_on

  name        = "${var.project}-f5"
  description = "F5 BIG-IP Advanced WAF"
  vpc_id      = aws_vpc.ingress[0].id

  ingress {
    description = "Traffic tu NLB o public subnet"
    from_port   = var.nlb_listener_port
    to_port     = var.nlb_listener_port
    protocol    = "tcp"
    cidr_blocks = [for s in aws_subnet.ingress_public : s.cidr_block]
  }

  ingress {
    description = "Quan tri tu mgmt subnet"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["10.0.50.0/24"]
  }

  egress {
    description = "Toi app trong spoke va ra Internet (license, update)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-f5" }
}

resource "aws_instance" "f5" {
  count = local.app_on

  ami           = var.f5_ami_id != "" ? var.f5_ami_id : one(data.aws_ami.f5[*].id)
  instance_type = var.f5_instance_type

  subnet_id              = aws_subnet.ingress_f5[0].id
  vpc_security_group_ids = [aws_security_group.f5[0].id]
  iam_instance_profile   = aws_iam_instance_profile.f5[0].name

  # Runtime Init: cai DO/AS3/TS roi ap declaration.
  # Chi tiet tung declaration o doc 18.
  user_data = templatefile("${path.module}/templates/f5-runtime-init.yaml", {
    admin_secret_name = aws_secretsmanager_secret.f5_admin[0].name
    hostname          = "bigip.${var.project}.internal"
    region            = var.region
    config_bucket     = aws_s3_bucket.f5_config[0].id
    listener_port     = var.nlb_listener_port

    # Truyen dang LIST, khong phai chuoi noi bang dau phay:
    # danh sach rong van sinh ra YAML hop le.
    app_pool_members = [for k, v in aws_instance.test : v.private_ip]
  })

  root_block_device {
    volume_size = 82
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.project}-f5" }
}

########################################
# Route - chen GWLB vao duong vao
########################################

# Route table gan TRUC TIEP vao IGW (edge association).
# Day la co che lam cho thanh tra trong suot hoat dong:
# traffic vao tu Internet bi ep qua GWLBe truoc khi toi NLB.
resource "aws_route_table" "igw_edge" {
  count = local.app_on

  vpc_id = aws_vpc.ingress[0].id
  tags   = { Name = "${var.project}-igw-edge-rt" }
}

# MOI subnet public mot route: mot aws_route chi mang duoc MOT
# destination. Voi 2-3 AZ, thieu route cua mot AZ nghia la luu luong
# vao node NLB o AZ do di THANG toi NLB, khong qua Palo Alto - mot
# duong vong quanh appliance ma khong co gi bao.
resource "aws_route" "igw_edge_to_gwlbe" {
  for_each = local.app_on > 0 ? aws_subnet.ingress_public : {}

  route_table_id         = aws_route_table.igw_edge[0].id
  destination_cidr_block = each.value.cidr_block
  vpc_endpoint_id        = aws_vpc_endpoint.gwlbe[0].id
}

resource "aws_route_table_association" "igw_edge" {
  count = local.app_on

  gateway_id     = aws_internet_gateway.ingress[0].id
  route_table_id = aws_route_table.igw_edge[0].id
}

# GWLBe subnet: thanh tra xong thi ra IGW
resource "aws_route_table" "ingress_gwlbe" {
  count = local.app_on

  vpc_id = aws_vpc.ingress[0].id
  tags   = { Name = "${var.project}-gwlbe-rt" }
}

resource "aws_route" "gwlbe_to_igw" {
  count = local.app_on

  route_table_id         = aws_route_table.ingress_gwlbe[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.ingress[0].id
}

resource "aws_route_table_association" "ingress_gwlbe" {
  count = local.app_on

  subnet_id      = aws_subnet.ingress_gwlbe[0].id
  route_table_id = aws_route_table.ingress_gwlbe[0].id
}

# Appliance subnet: PA can ra Internet cho license va update
resource "aws_route_table" "ingress_appliance" {
  count = local.app_on

  vpc_id = aws_vpc.ingress[0].id
  tags   = { Name = "${var.project}-appliance-rt" }
}

resource "aws_route" "appliance_to_igw" {
  count = local.app_on

  route_table_id         = aws_route_table.ingress_appliance[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.ingress[0].id
}

resource "aws_route_table_association" "ingress_appliance" {
  count = local.app_on

  subnet_id      = aws_subnet.ingress_appliance[0].id
  route_table_id = aws_route_table.ingress_appliance[0].id
}

# F5 subnet: xuong app qua TGW, ra Internet qua GWLBe (van bi PA thanh tra)
resource "aws_route_table" "ingress_f5" {
  count = local.app_on

  vpc_id = aws_vpc.ingress[0].id
  tags   = { Name = "${var.project}-f5-rt" }
}

resource "aws_route" "f5_to_internal" {
  count = local.app_on

  route_table_id         = aws_route_table.ingress_f5[0].id
  destination_cidr_block = var.internal_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.ingress]
}

resource "aws_route" "f5_to_gwlbe" {
  count = local.app_on

  route_table_id         = aws_route_table.ingress_f5[0].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = aws_vpc_endpoint.gwlbe[0].id
}

resource "aws_route_table_association" "ingress_f5" {
  count = local.app_on

  subnet_id      = aws_subnet.ingress_f5[0].id
  route_table_id = aws_route_table.ingress_f5[0].id
}

# Mgmt subnet: ra Internet truc tiep (khong qua PA de tranh khoa minh ra ngoai)
resource "aws_route_table" "ingress_mgmt" {
  count = local.app_on

  vpc_id = aws_vpc.ingress[0].id
  tags   = { Name = "${var.project}-mgmt-rt" }
}

resource "aws_route" "mgmt_to_igw" {
  count = local.app_on

  route_table_id         = aws_route_table.ingress_mgmt[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.ingress[0].id
}

resource "aws_route_table_association" "ingress_mgmt" {
  count = local.app_on

  subnet_id      = aws_subnet.ingress_mgmt[0].id
  route_table_id = aws_route_table.ingress_mgmt[0].id
}
