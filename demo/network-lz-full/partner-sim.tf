########################################
# DOI TAC GIA LAP - "on-premise" cua ho
#
# Mot VPC hoan toan tach biet, KHONG noi vao TGW, KHONG peering. Duong
# duy nhat toi landing zone la IPsec qua Internet - dung nhu mot doi
# tac that.
#
# EC2 chay strongSwan dong hai vai:
#   - customer gateway (dau kia cua duong ham)
#   - may cua doi tac (cho tu do curl vao dich vu ban cong bo)
#
# VI SAO PHAI GIA LAP THAY VI KHAI IP DOI TAC THAT
#
# Khai IP that thi Terraform tao xong VPN connection va tunnel nam o
# trang thai DOWN cho toi khi phia ho cau hinh - co the vai tuan. Trong
# khoang do KHONG PHEP KIEM NAO chay duoc: route dung hay sai, NAT co
# doi dia chi khong, firewall co chan dung cho khong - tat ca deu chua
# tra loi duoc.
#
# Voi dau kia do chinh ta dung, duong ham LEN THAT, va moi thu tren
# tuyen duoc do bang goi tin that. Khi cam doi tac that vao, chi doi
# aws_customer_gateway.ip_address - phan con lai da duoc chung minh.
#
########################################
# PHAN NAY LA PHAN DE HONG NHAT TRONG CA BO
#
# Cau hinh IPsec cua strongSwan viet trong user_data, va no khong duoc
# kiem chung boi terraform plan, terraform validate, hay bat ky cai gi
# ngoai viec duong ham co len hay khong.
#
# Khi tunnel khong len, doc theo thu tu nay:
#
#   aws ssm start-session --target <id cua strongSwan>
#   sudo cat /var/log/user-data.log          # goi cai duoc khong
#   sudo strongswan statusall                # SA co len khong
#   sudo journalctl -u strongswan -n 50      # loi thuc su
#   ip route show table all | grep vti       # route co gan vao vti chua
#
# verify.sh muc 10 in trang thai tunnel doc tu AWS, nen no noi duoc
# "chua len" ngay - khong phai doan tu viec ping khong thong.
########################################

resource "aws_vpc" "partner_sim" {
  count = local.ptn

  cidr_block           = var.partner_sim_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-partner-sim-vpc" }
}

resource "aws_internet_gateway" "partner_sim" {
  count = local.ptn

  vpc_id = aws_vpc.partner_sim[0].id
  tags   = { Name = "${var.project}-partner-sim-igw" }
}

resource "aws_subnet" "partner_sim" {
  count = local.ptn

  vpc_id            = aws_vpc.partner_sim[0].id
  availability_zone = local.primary_az
  cidr_block        = cidrsubnet(var.partner_sim_cidr, 8, 0)

  tags = { Name = "${var.project}-partner-sim", Tier = "partner-sim" }
}

resource "aws_route_table" "partner_sim" {
  count = local.ptn

  vpc_id = aws_vpc.partner_sim[0].id
  tags   = { Name = "${var.project}-partner-sim-rt" }
}

# Duong ra Internet - de dung duoc IPsec va de SSM agent dang ky.
#
# KHONG co route nao toi 10.9.0.0/16 o day. Duong toi landing zone
# nam TRONG duong ham, gan vao interface vti - do la viec cua
# strongSwan, khong phai cua VPC route table.
resource "aws_route" "partner_sim_igw" {
  count = local.ptn

  route_table_id         = aws_route_table.partner_sim[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.partner_sim[0].id
}

resource "aws_route_table_association" "partner_sim" {
  count = local.ptn

  subnet_id      = aws_subnet.partner_sim[0].id
  route_table_id = aws_route_table.partner_sim[0].id
}

########################################
# EIP - phai co TRUOC customer gateway
#
# aws_customer_gateway.ip_address doi mot IP biet o luc plan. Gan EIP
# vao instance roi doc instance.public_ip la mot vong: instance can
# user_data, user_data can VPN connection, VPN connection can customer
# gateway, customer gateway can IP.
#
# Tach EIP ra thanh resource rieng cat vong do: EIP -> CGW -> VPN ->
# user_data -> instance -> gan EIP vao instance.
########################################

resource "aws_eip" "partner_sim" {
  count = local.ptn

  domain = "vpc"
  tags   = { Name = "${var.project}-partner-sim-eip" }
}

resource "aws_eip_association" "partner_sim" {
  count = local.ptn

  instance_id   = aws_instance.partner_sim[0].id
  allocation_id = aws_eip.partner_sim[0].id
}

########################################
# Security group
#
# IPsec can UDP 500 (IKE) va UDP 4500 (NAT-T). NAT-T la bat buoc o
# day: EC2 nhin thay IP rieng cua chinh no, con AWS VPN nhin thay EIP
# - co NAT o giua, nen ESP tho khong qua duoc.
########################################

resource "aws_security_group" "partner_sim" {
  count = local.ptn

  name        = "${var.project}-partner-sim"
  description = "strongSwan gia lap thiet bi VPN cua doi tac"
  vpc_id      = aws_vpc.partner_sim[0].id

  ingress {
    description = "IKE"
    from_port   = 500
    to_port     = 500
    protocol    = "udp"
    cidr_blocks = [
      "${aws_vpn_connection.partner[0].tunnel1_address}/32",
      "${aws_vpn_connection.partner[0].tunnel2_address}/32",
    ]
  }

  ingress {
    description = "IPsec NAT-T"
    from_port   = 4500
    to_port     = 4500
    protocol    = "udp"
    cidr_blocks = [
      "${aws_vpn_connection.partner[0].tunnel1_address}/32",
      "${aws_vpn_connection.partner[0].tunnel2_address}/32",
    ]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-partner-sim-sg" }
}

########################################
# EC2 strongSwan
########################################

resource "aws_iam_role" "partner_sim" {
  count = local.ptn

  name = "${var.project}-partner-sim-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "partner_sim" {
  count = local.ptn

  role       = aws_iam_role.partner_sim[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "partner_sim" {
  count = local.ptn

  name = "${var.project}-partner-sim-ssm"
  role = aws_iam_role.partner_sim[0].name
}

data "aws_ssm_parameter" "partner_sim_ami" {
  count = local.ptn
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "partner_sim" {
  count = local.ptn

  ami           = data.aws_ssm_parameter.partner_sim_ami[0].value
  instance_type = var.instance_type
  subnet_id     = aws_subnet.partner_sim[0].id

  vpc_security_group_ids = [aws_security_group.partner_sim[0].id]
  iam_instance_profile   = aws_iam_instance_profile.partner_sim[0].name

  # IP public TAM de SSM agent dang ky duoc truoc khi EIP duoc gan.
  # Khong co no thi instance khong ra duoc Internet, agent khong dang
  # ky, va ban khong vao xem duoc vi sao tunnel khong len.
  associate_public_ip_address = true

  # source_dest_check = false: bat buoc voi may lam router.
  #
  # Mac dinh EC2 vut moi goi tin ma dia chi nguon/dich khong phai cua
  # chinh no. Voi mot con dinh dinh tuyen luu luong qua duong ham thi
  # do dung la viec no phai lam.
  source_dest_check = false

  metadata_options {
    http_tokens = "required"
  }

  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/strongswan.sh.tftpl", {
    # Dau kia cua duong ham - AWS
    tunnel1_address = aws_vpn_connection.partner[0].tunnel1_address
    tunnel2_address = aws_vpn_connection.partner[0].tunnel2_address
    tunnel1_psk     = aws_vpn_connection.partner[0].tunnel1_preshared_key
    tunnel2_psk     = aws_vpn_connection.partner[0].tunnel2_preshared_key

    # Dia chi trong duong ham. AWS goi ben minh la "vgw inside", ben
    # kia la "cgw inside" - o day ta LA ben kia.
    tunnel1_cgw_inside = aws_vpn_connection.partner[0].tunnel1_cgw_inside_address
    tunnel1_vgw_inside = aws_vpn_connection.partner[0].tunnel1_vgw_inside_address
    tunnel2_cgw_inside = aws_vpn_connection.partner[0].tunnel2_cgw_inside_address
    tunnel2_vgw_inside = aws_vpn_connection.partner[0].tunnel2_vgw_inside_address

    # leftid PHAI la EIP, khong phai IP rieng cua interface.
    #
    # Co NAT giua EC2 va Internet, nen AWS nhin thay goi tin den tu
    # EIP. Khai leftid la IP rieng thi IKE that bai o buoc xac thuc
    # danh tinh, va thong bao noi ve "no matching peer config" - dung
    # nhung khong chi vao dia chi.
    local_id = aws_eip.partner_sim[0].public_ip

    # Dai ban CONG BO cho doi tac. Chi hai dai nay duoc gan vao vti,
    # nen may nay khong the goi toi bat cu dia chi nao khac cua landing
    # zone - ke ca khi route table cua AWS cho phep.
    remote_cidrs = local.partner_advertised

    local_cidr   = var.partner_sim_cidr
    service_port = var.partner_service_port

    # TEN DNS cua NLB, khong phai mot IP doan tu dai subnet.
    #
    # NLB nhan IP tu AWS trong dai 10.9.100.0/24 va 10.9.101.0/24, va
    # chung KHONG co dia chi co dinh - doan ".100" la doan. Ten DNS
    # phan giai duoc tu trong duong ham vi VPC bat enable_dns_support.
    nlb_dns = aws_lb.partner[0].dns_name
  })

  tags = { Name = "${var.project}-partner-sim" }
}
