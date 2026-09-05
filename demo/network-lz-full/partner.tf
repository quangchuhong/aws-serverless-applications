########################################
# 3RD-PARTY VPC + SITE-TO-SITE VPN - doc 16
#
# Nguyen tac dau tien cua doc 16: DOI TAC KHONG BAO GIO CHAM VAO SPOKE.
#
# Sai lam pho bien nhat la dung VPN thang vao TGW roi mo route toi VPC
# ung dung. Lam vay thi doi tac nam TRONG mang cua ban, chi bi gioi han
# bang route va security group - va mot dong route sai la ho thay ca
# 10.0.0.0/8.
#
# Mo hinh o day: 3rd-party VPC lam VUNG DEM. Doi tac vao toi do, khong
# xa hon. Muon di tiep phai qua mot diem TAI KHOI TAO.
#
########################################
# VI SAO PHAI CO DIEM TAI KHOI TAO
#
# VPC KHONG DINH TUYEN BAC CAU. Goi tin vao VPC qua VGW khong the di
# tiep ra TGW attachment cua chinh VPC do - AWS chan thang, khong co
# route table nao sua duoc.
#
# Nen moi chieu can mot thu DUNG luong lai roi phat lai:
#
#   doi tac -> ban   NLB noi bo. Doi tac goi 10.9.100.x (dia chi
#                    NLB, NAM TRONG VPC nen VGW giao duoc). NLB mo
#                    ket noi MOI toi spoke, va ket noi moi do di ra
#                    bang TGW attachment binh thuong.
#
#   ban -> doi tac   Private NAT Gateway. Goi tu spoke vao VPC nay
#                    qua TGW attachment, route tro vao NAT, NAT doi
#                    nguon thanh 10.9.10.x roi day ra VGW.
#
# Hai thiet bi, hai chieu, va ca hai deu la thiet bi AWS quan - khong
# phai EC2 tu dung.
#
########################################
# BA LOP KIEM SOAT CHONG LEN NHAU
#
#   1. VPN static route  Doi tac CHI hoc duoc 10.9.10.0/24 va
#                        10.9.100.0/24. Ho khong biet - va khong nen
#                        biet - 10.20.0.0/16 ton tai.
#   2. rtb-partner       3rd-party VPC chi di duoc toi security VPC.
#                        KHONG propagate tu spoke nao.
#   3. Network Firewall  Tung cap IP/port cu the moi duoc qua.
#
# Bo mot lop van con hai. Do la ca y do.
########################################

locals {
  # Bat/tat toan bo nhanh nay. Mot bien duy nhat, giong local.fw.
  ptn = var.enable_partner_vpn ? 1 : 0

  # Dai NAT va dai NLB - hai thu DUY NHAT doi tac duoc biet.
  #
  # Tach ra thanh local vi chung xuat hien o SAU cho: route VPN, rule
  # firewall, security group, va tai lieu ban dua cho doi tac. Go tay
  # o sau cho la sau co hoi go sai mot chu so.
  partner_nat_cidr = cidrsubnet(var.partner_vpc_cidr, 8, 10) # 10.9.10.0/24

  # Dai NLB: MOT prefix phu HET moi subnet nlb, khong phai rieng cai o
  # AZ dau.
  #
  # NLB noi bo lay mot dia chi o MOI AZ - o day la 10.9.100.0/24 va
  # 10.9.101.0/24. Truoc day cho nay ghi cidrsubnet(..., 8, 100), tuc
  # chi AZ dau, va chinh chu thich o muc "3RD-PARTY VPC" ben duoi da
  # noi dung ca hai dai - code va chu thich lech nhau.
  #
  # Hong theo kieu te nhat: ten DNS cua NLB tra ve CA HAI dia chi, nen
  # doi tac goi duoc hay khong TUY VAO dia chi nao duoc chon. Mot phep
  # thu thanh cong khong chung minh duoc gi, va mot phep thu that bai
  # doc nhu loi ngau nhien.
  #
  # /23 phu 10.9.100.0/24 + 10.9.101.0/24. Them AZ thu ba thi khong du
  # nua - check "partner_nlb_span_covers_all_azs" ben duoi chan viec do.
  partner_nlb_cidr = cidrsubnet(var.partner_vpc_cidr, 7, 50) # 10.9.100.0/23

  # Dai ban CONG BO cho doi tac. Chi hai cai tren, khong bao gio la
  # 10.0.0.0/8. Xem doc 16 muc 6 - bang thoa thuan CIDR.
  partner_advertised = [local.partner_nat_cidr, local.partner_nlb_cidr]
}

########################################
# 3RD-PARTY VPC
#
# CIDR subnet, theo doc 16 muc 3:
#   nlb   10.9.100.0/24  10.9.101.0/24   dia chi ao doi tac goi toi
#   nat   10.9.10.0/24                   private NAT Gateway
#   tgw   10.9.20.0/28   10.9.21.0/28    TGW attachment
########################################

resource "aws_vpc" "partner" {
  count = local.ptn

  cidr_block           = var.partner_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-3rd-party-vpc" }
}

resource "aws_subnet" "partner_nlb" {
  for_each = var.enable_partner_vpn ? local.azs : {}

  vpc_id            = aws_vpc.partner[0].id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.partner_vpc_cidr, 8, 100 + each.value)

  tags = { Name = "${var.project}-partner-nlb-${each.key}", Tier = "partner-nlb" }
}

# MOT NAT thoi, dat o AZ dau.
#
# That ra nen mot cai moi AZ: NAT o AZ-a chet thi luong tu AZ-b cung
# chet theo. Demo giu mot cai de bot $0.045/gio, va vi thu can chung
# minh o day la DUONG DI, khong phai tinh san sang.
#
# Doi lai: luu luong tu tgw subnet o AZ-b sang NAT o AZ-a la cheo AZ,
# tinh phi data transfer. O muc demo thi khong dang ke.
resource "aws_subnet" "partner_nat" {
  count = local.ptn

  vpc_id            = aws_vpc.partner[0].id
  availability_zone = local.primary_az
  cidr_block        = local.partner_nat_cidr

  tags = { Name = "${var.project}-partner-nat", Tier = "partner-nat" }
}

resource "aws_subnet" "partner_tgw" {
  for_each = var.enable_partner_vpn ? local.azs : {}

  vpc_id            = aws_vpc.partner[0].id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.partner_vpc_cidr, 12, 320 + each.value) # 10.9.20.0/28

  tags = { Name = "${var.project}-partner-tgw-${each.key}", Tier = "tgw" }
}

########################################
# VIRTUAL PRIVATE GATEWAY
#
# VPN ket cuoi o VGW cua VPC nay, KHONG phai o TGW. Doc 16 muc 4 so
# hai cach:
#
#   VPN -> TGW attachment   luu luong doi tac vao thang TGW
#   VPN -> VGW cua VPC nay  luu luong BI GIU TRONG VPC truoc
#
# Cai thu hai la ranh gioi that. Voi cach thu nhat, mot dong route sai
# trong TGW la doi tac di duoc toi cho khong nen di. Voi cach nay,
# ngay ca route sai cung khong du - van phai qua NLB hoac NAT.
########################################

resource "aws_vpn_gateway" "partner" {
  count = local.ptn

  vpc_id = aws_vpc.partner[0].id

  # ASN phia AWS. De mac dinh 64512 cung duoc; khai ro de tai lieu
  # dua cho doi tac khop voi thuc te.
  amazon_side_asn = var.partner_amazon_asn

  tags = { Name = "${var.project}-partner-vgw" }
}

########################################
# CUSTOMER GATEWAY - dau kia cua duong ham
#
# Voi doi tac THAT: ip_address la IP cong khai thiet bi VPN cua ho,
# bgp_asn la ASN ho cung cap. Hai so nay nam trong ho so doi tac
# (doc 16 muc 10.1).
#
# O day: IP cong khai cua EC2 strongSwan trong partner-sim VPC. Xem
# partner-sim.tf.
########################################

resource "aws_customer_gateway" "partner" {
  count = local.ptn

  type       = "ipsec.1"
  ip_address = aws_eip.partner_sim[0].public_ip
  bgp_asn    = var.partner_bgp_asn

  tags = { Name = "${var.project}-partner-cgw" }
}

########################################
# PSK - sinh ra, khong go tay
#
# Rang buoc cua AWS: 8-64 ky tu, chi chu-so-dau cham-gach duoi, va
# KHONG duoc bat dau bang so 0. Tien to "lz" cho chac.
#
# Voi doi tac that, PSK phai chuyen qua kenh rieng (doc 16 muc 5.1) -
# khong bao giờ nam trong terraform.tfvars duoc commit.
########################################

resource "random_password" "partner_psk" {
  count = local.ptn * 2

  length  = 32
  special = false
  upper   = true
  lower   = true
  numeric = true
}

resource "aws_vpn_connection" "partner" {
  count = local.ptn

  vpn_gateway_id      = aws_vpn_gateway.partner[0].id
  customer_gateway_id = aws_customer_gateway.partner[0].id
  type                = "ipsec.1"

  # TINH, khong BGP.
  #
  # BGP tot hon cho doi tac that: ho rut route khi dut, khong phai goi
  # dien cho ai. Nhung no doi phia ben kia biet cau hinh BGP, va o day
  # phia ben kia la mot con EC2 ta tu dung - them BGP la them mot thu
  # nua co the hong ma khong lien quan gi toi thu dang chung minh.
  static_routes_only = true

  # Dia chi trong duong ham khai TUONG MINH.
  #
  # De AWS tu chon thi moi lan tao lai la mot dai khac, va cau hinh
  # strongSwan - von nhung dia chi nay vao user_data - se lech. Khai
  # ro thi dung lai bao nhieu lan cung ra dung mot cau hinh.
  tunnel1_inside_cidr   = var.partner_tunnel_inside_cidrs[0]
  tunnel2_inside_cidr   = var.partner_tunnel_inside_cidrs[1]
  tunnel1_preshared_key = "lz${random_password.partner_psk[0].result}"
  tunnel2_preshared_key = "lz${random_password.partner_psk[1].result}"

  tags = { Name = "${var.project}-partner-vpn" }
}

# Route tinh: dai cua doi tac di qua duong ham nao.
#
# Voi static_routes_only = true thi day la CACH DUY NHAT VGW biet
# 172.16.0.0/16 nam sau VPN. Thieu dong nay: duong ham UP, ping khong
# thong, va khong co gi bao vi tunnel bao "available".
resource "aws_vpn_connection_route" "partner" {
  count = local.ptn

  vpn_connection_id      = aws_vpn_connection.partner[0].id
  destination_cidr_block = var.partner_sim_cidr
}

# VGW lan route cua no vao bang route cua VPC.
#
# Chi bat cho bang NAT va NLB. KHONG bat cho bang tgw: luong tu spoke
# di ra doi tac phai vao NAT truoc, va neu bang tgw hoc duoc route
# thang toi VGW thi no se di thang - khong NAT, doi tac thay dia chi
# that cua spoke, va neu CIDR trung nhau thi goi tin khong bao gio ve.
resource "aws_vpn_gateway_route_propagation" "partner_nat" {
  count = local.ptn

  vpn_gateway_id = aws_vpn_gateway.partner[0].id
  route_table_id = aws_route_table.partner_nat[0].id
}

resource "aws_vpn_gateway_route_propagation" "partner_nlb" {
  count = local.ptn

  vpn_gateway_id = aws_vpn_gateway.partner[0].id
  route_table_id = aws_route_table.partner_nlb[0].id
}

########################################
# PRIVATE NAT GATEWAY - chieu BAN GOI DOI TAC
#
# connectivity_type = "private": khong EIP, khong ra Internet. No chi
# lam mot viec - doi dia chi nguon.
#
# Vi sao can, ngay ca khi CIDR khong trung: doi tac thay nguon la
# 10.9.10.x thay vi 10.20.1.5. Ho khong hoc duoc gi ve cau truc mang
# cua ban tu luu luong di den. Khi CIDR CO trung thi no chuyen tu
# "nen co" thanh "khong co thi khong dinh tuyen duoc".
########################################

resource "aws_nat_gateway" "partner" {
  count = local.ptn

  connectivity_type = "private"
  subnet_id         = aws_subnet.partner_nat[0].id

  tags = { Name = "${var.project}-partner-nat" }
}

########################################
# TGW ATTACHMENT
########################################

resource "aws_ec2_transit_gateway_vpc_attachment" "partner" {
  count = local.ptn

  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.partner[0].id
  subnet_ids         = [for z in var.availability_zones : aws_subnet.partner_tgw[z].id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-tgwa-partner" }
}

########################################
# BANG ROUTE TRONG 3RD-PARTY VPC
#
# Ba bang, ba vai. Doc ky phan nay - day la cho quyet dinh luu luong
# di dau, va mot dong sai o day khong bao loi, chi lam mot chieu im
# lang khong hoat dong.
########################################

# 1. Bang cua subnet NLB
#
# NLB nhan ket noi tu doi tac (172.16.x, hoc qua VGW propagation) va
# mo ket noi moi toi spoke (10.0.0.0/8 -> TGW).
resource "aws_route_table" "partner_nlb" {
  count = local.ptn

  vpc_id = aws_vpc.partner[0].id
  tags   = { Name = "${var.project}-partner-nlb-rt" }
}

resource "aws_route" "partner_nlb_to_tgw" {
  count = local.ptn

  route_table_id         = aws_route_table.partner_nlb[0].id
  destination_cidr_block = var.internal_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.partner]
}

resource "aws_route_table_association" "partner_nlb" {
  for_each = var.enable_partner_vpn ? local.azs : {}

  subnet_id      = aws_subnet.partner_nlb[each.key].id
  route_table_id = aws_route_table.partner_nlb[0].id
}

# 2. Bang cua subnet NAT
#
# NAT nhan luong tu spoke (den qua TGW), doi nguon, roi day ra VGW.
# Chieu ve: doi tac tra loi ve 10.9.10.x, VGW giao thang cho NAT vi
# dia chi do NAM TRONG VPC - khong dinh tuyen bac cau, khong van de.
resource "aws_route_table" "partner_nat" {
  count = local.ptn

  vpc_id = aws_vpc.partner[0].id
  tags   = { Name = "${var.project}-partner-nat-rt" }
}

# NAT tra goi ve cho spoke that sau khi go NAT
resource "aws_route" "partner_nat_to_tgw" {
  count = local.ptn

  route_table_id         = aws_route_table.partner_nat[0].id
  destination_cidr_block = var.internal_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.partner]
}

resource "aws_route_table_association" "partner_nat" {
  count = local.ptn

  subnet_id      = aws_subnet.partner_nat[0].id
  route_table_id = aws_route_table.partner_nat[0].id
}

# 3. Bang cua subnet TGW
#
# DONG QUAN TRONG NHAT TRONG CA FILE.
#
# Luong tu spoke di ra doi tac den o day. Route nay day no vao NAT
# thay vi ra thang VGW. Bo dong nay di thi:
#   - goi tin van toi duoc doi tac (neu CIDR khong trung)
#   - nguon la 10.20.1.5 that, khong phai 10.9.10.x
#   - doi tac hoc duoc cau truc mang cua ban tu luu luong
#   - va neu CIDR TRUNG thi goi tra ve khong bao gio den
#
# Ca bon hau qua deu khong phat ra loi o dau ca.
resource "aws_route" "partner_tgw_to_nat" {
  count = local.ptn

  route_table_id         = aws_route_table.partner_tgw[0].id
  destination_cidr_block = var.partner_sim_cidr
  nat_gateway_id         = aws_nat_gateway.partner[0].id
}

resource "aws_route_table" "partner_tgw" {
  count = local.ptn

  vpc_id = aws_vpc.partner[0].id
  tags   = { Name = "${var.project}-partner-tgw-rt" }
}

resource "aws_route_table_association" "partner_tgw" {
  for_each = var.enable_partner_vpn ? local.azs : {}

  subnet_id      = aws_subnet.partner_tgw[each.key].id
  route_table_id = aws_route_table.partner_tgw[0].id
}

########################################
# rtb-partner - BANG ROUTE TABLE THU NAM CUA TGW
#
# doc 16 muc 7. Khac ba bang kia o mot diem:
#
#   KHONG PROPAGATE TU DAU CA.
#
# rtb-spokes hoc duoc gi tu propagation? Khong gi - no cung chi co
# mot dong tinh. Nhung rtb-security thi propagate tu moi spoke.
#
# O day co tinh de trong: 3rd-party VPC khong duoc phep hoc dia chi
# cua bat ky spoke nao. No chi biet mot duong - vao security VPC. Sau
# do firewall quyet dinh.
########################################

resource "aws_ec2_transit_gateway_route_table" "partner" {
  count = local.ptn

  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "${var.project}-rtb-partner" }
}

resource "aws_ec2_transit_gateway_route_table_association" "partner" {
  count = local.ptn

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.partner[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.partner[0].id
}

resource "aws_ec2_transit_gateway_route" "partner_default" {
  count = local.ptn

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = local.inspect_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.partner[0].id
}

########################################
# DUONG VE - hai dong de quen nhat
#
# rtb-security co 0.0.0.0/0 -> egress. Nghia la goi tra loi gui ve
# 3rd-party VPC se bi day ra Internet neu khong co route tinh.
#
# Trieu chung khi thieu: doi tac goi vao, request toi duoc spoke, spoke
# xu ly xong, va khong ai nhan duoc phan hoi. Dung kieu hong da gap voi
# ingress VPC (xem tgw.tf, aws_ec2_transit_gateway_route.security_to_ingress).
########################################

resource "aws_ec2_transit_gateway_route" "security_to_partner" {
  count = var.enable_partner_vpn && var.enable_firewall ? 1 : 0

  destination_cidr_block         = var.partner_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.partner[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security[0].id
}

# Chieu BAN GOI DOI TAC: dai cua doi tac nam NGOAI 10.0.0.0/8, nen
# 0.0.0.0/0 -> egress se nuot no. Phai co dong nay de sau khi qua
# thanh tra, goi tin quay ve 3rd-party VPC chu khong ra Internet.
resource "aws_ec2_transit_gateway_route" "security_to_partner_remote" {
  count = var.enable_partner_vpn && var.enable_firewall ? 1 : 0

  destination_cidr_block         = var.partner_sim_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.partner[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security[0].id
}

# Khi TAT firewall, rtb-spokes tro thang sang egress - cung nuot mat
# dai doi tac. Them route tuong ung vao rtb-spokes.
resource "aws_ec2_transit_gateway_route" "spokes_to_partner_direct" {
  count = var.enable_partner_vpn && !var.enable_firewall ? 1 : 0

  destination_cidr_block         = var.partner_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.partner[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

########################################
# NLB - diem doi tac goi toi
#
# Dia chi ao doc 16 muc 6 goi la "dia chi dich vu doi tac goi": doi
# tac biet 10.9.100.x, khong biet spoke that nam o dau.
#
# NLB nhan IP target NAM NGOAI VPC cua no - target la EC2 trong spoke,
# toi qua TGW. AWS ho tro dieu nay cho dai RFC1918.
########################################

########################################
# SECURITY GROUP CUA NLB DOI TAC
#
# KHONG co khoi ingress/egress LONG NHAU o day - co chu y.
#
# NLB co security group, va no loc luu luong toi TUNG LISTENER. Lop
# ops mo them listener cho dich vu moi, nen no cung phai mo them rule
# tuong ung - neu khong, goi tin bi vut TRUOC khi toi listener. Khong
# log, khong loi, chi het gio.
#
# Ma mot khoi `ingress` long trong aws_security_group thi SO HUU TOAN
# BO danh sach rule: moi lan apply layer cha, Terraform xoa sach moi
# rule no khong biet - ke ca rule lop ops vua them.
#
# Trieu chung cua viec do la thu te nhat trong ca bo: doi tac ket noi
# duoc, roi mot hom nao do ai apply layer cha thi ho mat ket noi, va
# chay lai apply o lop ops thi ho co lai. "Chap chon" theo dung nghia,
# va khong co gi trong log noi tai sao.
#
# Tach ra thanh resource rieng thi hai layer cung them rule vao mot
# security group ma khong ai xoa cua ai.
########################################

resource "aws_security_group" "partner_nlb" {
  count = local.ptn

  name        = "${var.project}-partner-nlb"
  description = "Chi doi tac goi vao duoc"
  vpc_id      = aws_vpc.partner[0].id

  tags = { Name = "${var.project}-partner-nlb-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "partner_nlb" {
  count = local.ptn

  security_group_id = aws_security_group.partner_nlb[0].id
  description       = "Dich vu mac dinh - chi tu dai cua doi tac, qua VPN"

  cidr_ipv4   = var.partner_sim_cidr
  from_port   = var.partner_service_port
  to_port     = var.partner_service_port
  ip_protocol = "tcp"

  tags = { Name = "${var.project}-partner-nlb-${var.partner_service_port}" }
}

resource "aws_vpc_security_group_egress_rule" "partner_nlb" {
  count = local.ptn

  security_group_id = aws_security_group.partner_nlb[0].id
  description       = "Toi spoke qua TGW"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"

  tags = { Name = "${var.project}-partner-nlb-egress" }
}

resource "aws_lb" "partner" {
  count = local.ptn

  name               = "${var.project}-partner-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = [for z in var.availability_zones : aws_subnet.partner_nlb[z].id]
  security_groups    = [aws_security_group.partner_nlb[0].id]

  # Doi tac goi vao AZ nao thi phai toi duoc target o AZ khac.
  # Tat cai nay thi mot AZ khong co target la ket noi vao AZ do chet,
  # va trieu chung la "chap chon" chu khong phai "hong".
  enable_cross_zone_load_balancing = true

  tags = { Name = "${var.project}-partner-nlb" }
}

resource "aws_lb_target_group" "partner" {
  count = local.ptn

  name        = "${var.project}-partner-tg"
  port        = var.partner_service_port
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.partner[0].id

  health_check {
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = { Name = "${var.project}-partner-tg" }
}

# Target: EC2 kiem chung trong spoke.
#
# Uu tien spoke o ACCOUNT KHAC - do moi la thu dang chung minh: doi
# tac o ngoai Internet goi vao, qua VPN, qua NLB, qua TGW, qua
# firewall, toi mot VPC nam o mot AWS account hoan toan khac.
#
# availability_zone = "all" LA BAT BUOC voi IP nam ngoai VPC cua NLB.
# Thieu no thi API tu choi voi mot cau ve AZ khong hop le - dung, nhung
# khong noi rang nguyen nhan la target o ngoai VPC.
resource "aws_lb_target_group_attachment" "partner" {
  count = local.ptn

  target_group_arn  = aws_lb_target_group.partner[0].arn
  target_id         = local.partner_target_ip
  port              = var.partner_service_port
  availability_zone = "all"
}

resource "aws_lb_listener" "partner" {
  count = local.ptn

  load_balancer_arn = aws_lb.partner[0].arn
  port              = var.partner_service_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.partner[0].arn
  }
}

locals {
  # IP dich vu doi tac goi toi, giai theo thu tu uu tien:
  #   1. spoke remote dau tien  (chung minh duoc nhieu nhat)
  #   2. spoke local dau tien   (khi khong co spoke remote)
  #
  # try() vi ca hai deu co the rong. Khong giai duoc thi tra ve mot
  # dia chi khong ai o do - check ben duoi bat truong hop nay.
  partner_target_ip = try(
    values(local.remote_test_ips)[0],
    values(aws_instance.test)[0].private_ip,
    "127.0.0.1",
  )
}

########################################
# KIEM TRA CHEO
########################################

check "partner_has_a_target" {
  assert {
    condition     = !var.enable_partner_vpn || local.partner_target_ip != "127.0.0.1"
    error_message = "enable_partner_vpn = true nhung khong co EC2 nao de lam target cho NLB. Bat enable_test_instances hoac remote_test_instances - neu khong thi duong di co thong cung khong co gi tra loi, va phep kiem se bao 'khong thong' cho mot mang hoan toan dung."
  }
}

# Dai cua doi tac KHONG duoc nam trong internal_supernet.
#
# Trung thi rtb-security va rtb-spokes khong phan biet duoc dau la
# spoke dau la doi tac, va route tinh o tren se giam len propagation
# cua spoke. Day dung la truong hop "CIDR trung nhau" ma private NAT
# sinh ra de giai - nhung NAT giai phia BEN KIA duong ham, khong giai
# duoc viec hai dai giam nhau trong CHINH bang route cua ban.
check "partner_cidr_does_not_overlap_lz" {
  assert {
    condition = !var.enable_partner_vpn || !try(
      cidrhost(
        "${split("/", var.partner_sim_cidr)[0]}/${split("/", var.internal_supernet)[1]}", 0
      ) == cidrhost(var.internal_supernet, 0),
      false,
    )
    error_message = "partner_sim_cidr (${var.partner_sim_cidr}) nam TRONG internal_supernet (${var.internal_supernet}). Route tinh toi dai doi tac se giam len propagation cua spoke trong rtb-security, va TGW khong phan biet duoc hai ben. Doi dai cua doi tac sang mot dai khac han - 172.16.0.0/16 hoac 192.168.0.0/16."
  }
}

# Dai NLB cong bo phai phu HET moi subnet nlb.
#
# Thieu mot dai thi ten DNS cua NLB van tra ve dia chi trong dai do,
# va doi tac goi duoc hay khong tuy vao dia chi nao duoc chon. Mot
# phep thu thanh cong khong chung minh duoc gi.
#
# partner_nlb_cidr dang la /23 - du cho hai AZ. Them AZ thu ba thi
# phai noi rong thanh /22, va day la cho bao.
check "partner_nlb_span_covers_all_azs" {
  assert {
    condition = !var.enable_partner_vpn || alltrue([
      for az, i in local.azs : try(
        cidrhost(cidrsubnet(local.partner_nlb_cidr, 1, i), 0)
        == cidrhost(cidrsubnet(var.partner_vpc_cidr, 8, 100 + i), 0),
        false,
      )
    ])
    error_message = "partner_nlb_cidr (${local.partner_nlb_cidr}) khong phu het ${length(local.azs)} subnet nlb. Moi AZ mot dia chi NLB, va ten DNS tra ve TAT CA - dai nao khong duoc cong bo thi doi tac goi vao do se im lang. Noi rong prefix trong local.partner_nlb_cidr."
  }
}

check "partner_traffic_is_inspected" {
  assert {
    condition     = !var.enable_partner_vpn || var.enable_firewall
    error_message = "enable_partner_vpn = true nhung enable_firewall = false. Luu luong doi tac dang di thang toi spoke qua egress VPC, khong qua thanh tra nao. Day la mot trong ba lop kiem soat cua doc 16, va no la lop duy nhat nhin duoc vao tung cap IP/port."
  }
}
