########################################
# TRANSIT GATEWAY - trai tim cua thiet ke
#
# Ban than TGW khong tinh phi theo gio. Chi phi nam o ATTACHMENT.
########################################

resource "aws_ec2_transit_gateway" "hub" {
  description = "${var.project} hub"

  # Tat route table mac dinh de tu quan.
  # De mac dinh thi moi attachment tu dong hoc duong den nhau
  # -> mat cach ly spoke, va traffic khong qua firewall.
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"

  # Attachment tao TU ACCOUNT KHAC duoc chap nhan ngay.
  #
  # Thieu dong nay thi attachment cua spoke o account khac nam mai o
  # trang thai pendingAcceptance: khong loi, khong canh bao, va khong
  # mot goi tin nao di qua. Xem vpc-spokes-remote.tf.
  auto_accept_shared_attachments = "enable"

  tags = { Name = "${var.project}-tgw" }
}

########################################
# Attachment cua spoke
########################################

resource "aws_ec2_transit_gateway_vpc_attachment" "spoke" {
  for_each = var.spokes

  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.spoke[each.key].id
  subnet_ids         = [for z in var.availability_zones : aws_subnet.spoke_tgw["${each.key}-${z}"].id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-tgwa-${each.key}" }
}

########################################
# Route table
#
# enable_firewall = true  -> 4 bang (spokes, security, egress, ingress)
# enable_firewall = false -> 3 bang, spoke di thang sang egress
########################################

resource "aws_ec2_transit_gateway_route_table" "spokes" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "${var.project}-rtb-spokes" }
}

resource "aws_ec2_transit_gateway_route_table" "egress" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "${var.project}-rtb-egress" }
}

resource "aws_ec2_transit_gateway_route_table" "security" {
  count = local.fw

  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "${var.project}-rtb-security" }
}

resource "aws_ec2_transit_gateway_route_table" "ingress" {
  count = var.enable_ingress ? 1 : 0

  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "${var.project}-rtb-ingress" }
}

########################################
# Association - attachment nay dung bang nao
########################################

resource "aws_ec2_transit_gateway_route_table_association" "spokes" {
  for_each = var.spokes

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

resource "aws_ec2_transit_gateway_route_table_association" "egress" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

resource "aws_ec2_transit_gateway_route_table_association" "security" {
  count = local.fw

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.security[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security[0].id
}

resource "aws_ec2_transit_gateway_route_table_association" "ingress" {
  count = var.enable_ingress ? 1 : 0

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.ingress[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.ingress[0].id
}

########################################
# rtb-spokes
#
# MOT dong duy nhat. Phu ca Internet LAN spoke khac LAN ingress VPC.
# KHONG propagate tu spoke nao -> khong co duong tat giua cac spoke.
#
# Day la cau tra loi cho "co can route vpc-to-vpc khong":
# KHONG. Route nay da phu. Chi can them rule firewall.
########################################

locals {
  # Firewall bat  -> moi thu vao security VPC
  # Firewall tat  -> di thang egress (che do re, khong co east-west)
  inspect_attachment_id = var.enable_firewall ? aws_ec2_transit_gateway_vpc_attachment.security[0].id : aws_ec2_transit_gateway_vpc_attachment.egress.id
}

resource "aws_ec2_transit_gateway_route" "spokes_default" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = local.inspect_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

########################################
# rtb-security - CHI ton tai khi bat firewall
#
# Sau khi thanh tra, TGW quyet dinh gui goi di dau:
#   - ve spoke        (propagation)
#   - ve ingress VPC  (route tinh)   <- THIEU LA HONG, xem duoi
#   - ra Internet     (route tinh 0.0.0.0/0 -> egress)
########################################

resource "aws_ec2_transit_gateway_route_table_propagation" "spokes_to_security" {
  for_each = var.enable_firewall ? var.spokes : {}

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security[0].id
}

# *** ROUTE TINH VE INGRESS VPC ***
# Thieu dong nay: goi tra loi cua app gui cho NLB (dich 10.0.0.0/16)
# se khop 0.0.0.0/0 va bi day sang EGRESS VPC.
# Trieu chung: request vao toi app, app xu ly xong, nhung client
# khong bao gio nhan duoc phan hoi.
resource "aws_ec2_transit_gateway_route" "security_to_ingress" {
  count = var.enable_firewall && var.enable_ingress ? 1 : 0

  destination_cidr_block         = var.ingress_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.ingress[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security[0].id
}

# Chi nhung gi con lai - Internet that - moi ra egress VPC
resource "aws_ec2_transit_gateway_route" "security_to_egress" {
  count = local.fw

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security[0].id
}

########################################
# rtb-egress
#
# Firewall BAT : route tinh dua goi tra ve QUAY LAI security VPC
# Firewall TAT : propagate tu spoke (goi ve di thang, khong thanh tra)
#
# KHONG BAO GIO propagate khi firewall dang bat - do la duong
# lam luong bat doi xung va firewall stateful se drop.
########################################

resource "aws_ec2_transit_gateway_route" "egress_return_to_security" {
  count = local.fw

  destination_cidr_block         = var.internal_supernet
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.security[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spokes_to_egress" {
  for_each = var.enable_firewall ? {} : var.spokes

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

########################################
# rtb-ingress - tuong tu rtb-egress
########################################

resource "aws_ec2_transit_gateway_route" "ingress_to_security" {
  count = var.enable_firewall && var.enable_ingress ? 1 : 0

  destination_cidr_block         = var.internal_supernet
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.security[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.ingress[0].id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spokes_to_ingress" {
  for_each = !var.enable_firewall && var.enable_ingress ? var.spokes : {}

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.ingress[0].id
}

# Khi firewall TAT, spoke van can duong ve ingress VPC de tra loi NLB
resource "aws_ec2_transit_gateway_route" "spokes_to_ingress_direct" {
  count = !var.enable_firewall && var.enable_ingress ? 1 : 0

  destination_cidr_block         = var.ingress_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.ingress[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}
