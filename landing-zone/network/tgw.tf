########################################
# TRANSIT GATEWAY
#
# Ban than TGW KHONG tinh phi theo gio. Tien nam o ATTACHMENT
# (~$0.05/gio moi cai) va o luu luong di qua.
########################################

resource "aws_ec2_transit_gateway" "hub" {
  count    = local.enabled ? 1 : 0
  provider = aws.network

  description = "${var.project} landing zone hub"

  # TAT route table mac dinh - day la dong quan trong nhat ca file.
  #
  # De mac dinh thi MOI attachment tu dong hoc duong den nhau: spoke
  # app-dev goi thang duoc spoke app-prod, khong qua firewall, khong
  # ai cau hinh gi ca. Cach ly bien mat ma khong co thong bao nao.
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"

  # Account workload tu attach vao TGW da share. Khong bat cai nay
  # thi moi attachment nam o trang thai pendingAcceptance cho tay
  # nguoi duyet - va no se nam do rat lau.
  auto_accept_shared_attachments = "enable"

  # DNS resolution qua TGW: spoke phan giai duoc ten cua interface
  # endpoint dat trong security VPC.
  dns_support = "enable"

  tags = { Name = "${var.project}-tgw" }
}

########################################
# CHIA SE CHO CA TO CHUC QUA RAM
#
# Chia cho ARN cua to chuc chu khong liet ke tung account: account
# thu bay tu nhin thay TGW, khong phai sua gi o day.
########################################

resource "aws_ram_resource_share" "tgw" {
  count    = local.enabled && var.share_tgw_with_org ? 1 : 0
  provider = aws.network

  name = "${var.project}-tgw"

  # false = chi chia trong to chuc. Khong bao gio doi thanh true.
  allow_external_principals = false

  tags = { Name = "${var.project}-tgw-share" }
}

resource "aws_ram_resource_association" "tgw" {
  count    = local.enabled && var.share_tgw_with_org ? 1 : 0
  provider = aws.network

  resource_arn       = aws_ec2_transit_gateway.hub[0].arn
  resource_share_arn = aws_ram_resource_share.tgw[0].arn
}

resource "aws_ram_principal_association" "org" {
  count    = local.enabled && var.share_tgw_with_org ? 1 : 0
  provider = aws.network

  principal          = data.aws_organizations_organization.this.arn
  resource_share_arn = aws_ram_resource_share.tgw[0].arn
}

########################################
# ROUTE TABLE
#
# Doc 17 muc 4 goi bang nay la "bang chan ly duy nhat" - sai mot o
# la co luong lot firewall hoac dut ket noi.
#
#   rtb-spokes    moi spoke      0.0.0.0/0 -> security
#   rtb-security  security VPC   propagate tu moi spoke
#                                + route tinh cho dich khong phai spoke
#   rtb-egress    egress VPC     10.0.0.0/8 -> security
#
# rtb-ingress va rtb-partner chua tao - chua co VPC tuong ung.
########################################

resource "aws_ec2_transit_gateway_route_table" "spokes" {
  count    = local.enabled ? 1 : 0
  provider = aws.network

  transit_gateway_id = aws_ec2_transit_gateway.hub[0].id
  tags               = { Name = "${var.project}-rtb-spokes" }
}

resource "aws_ec2_transit_gateway_route_table" "security" {
  count    = local.fw
  provider = aws.network

  transit_gateway_id = aws_ec2_transit_gateway.hub[0].id
  tags               = { Name = "${var.project}-rtb-security" }
}

resource "aws_ec2_transit_gateway_route_table" "egress" {
  count    = local.enabled ? 1 : 0
  provider = aws.network

  transit_gateway_id = aws_ec2_transit_gateway.hub[0].id
  tags               = { Name = "${var.project}-rtb-egress" }
}

########################################
# rtb-spokes
#
# MOT dong duy nhat, va no phu ca Internet LAN spoke khac.
#
# Day la cau tra loi cho cau hoi "co can them route VPC-to-VPC
# khong": KHONG. Muon mo/dong east-west thi sua rule firewall
# (var.east_west_rules), route giu nguyen.
#
# KHONG propagate tu spoke nao vao bang nay - propagate la tao
# duong tat giua cac spoke, bo qua firewall.
########################################

locals {
  # Firewall bat -> moi thu vao security VPC.
  # Firewall tat -> di thang egress: re hon, nhung mat ca thanh tra
  #                 lan cach ly east-west.
  #
  # Dung one(...[*].id) chu KHONG phai [0].id: khi enable_firewall =
  # false thi count cua security attachment la 0, va [0] tren mot
  # resource count = 0 la "Invalid index" - ke ca khi nhanh do khong
  # duoc chon. one() tren splat tra ve null, an toan o moi to hop bien.
  inspect_attachment_id = (
    var.enable_firewall
    ? one(aws_ec2_transit_gateway_vpc_attachment.security[*].id)
    : one(aws_ec2_transit_gateway_vpc_attachment.egress[*].id)
  )
}

resource "aws_ec2_transit_gateway_route" "spokes_default" {
  count    = local.enabled ? 1 : 0
  provider = aws.network

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = local.inspect_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes[0].id
}

# Association cua spoke: attachment do account workload tao ra.
# Chua co dong nao o day = attachment khong thuoc bang nao = khong
# mot goi tin nao di qua duoc, ma khong co loi gi.
resource "aws_ec2_transit_gateway_route_table_association" "spokes" {
  for_each = local.enabled ? var.spoke_attachments : {}
  provider = aws.network

  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes[0].id
}

########################################
# rtb-security
#
# Sau khi thanh tra, TGW quyet dinh gui goi di dau:
#   - ve spoke        <- propagation tu chinh cac spoke
#   - ve ingress VPC  <- route tinh, DAT TRUOC 0.0.0.0/0
#   - ra Internet     <- route tinh 0.0.0.0/0 -> egress
#
# Doc 17 QT1: day la bang DUY NHAT duoc propagate. Ba bang kia dung
# route tinh. Propagate o rtb-egress khien goi tra ve di thang toi
# spoke, bo qua firewall - va luong bat doi xung thi firewall
# stateful drop luon.
########################################

resource "aws_ec2_transit_gateway_route_table_association" "security" {
  count    = local.fw
  provider = aws.network

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.security[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security[0].id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spokes_to_security" {
  for_each = local.fw == 1 ? var.spoke_attachments : {}
  provider = aws.network

  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security[0].id
}

# Firewall TAT: spoke phai vao rtb-egress de goi tra ve tim duoc
# duong. Day la che do re, khong co east-west inspection.
resource "aws_ec2_transit_gateway_route_table_propagation" "spokes_to_egress" {
  for_each = local.enabled && !var.enable_firewall ? var.spoke_attachments : {}
  provider = aws.network

  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress[0].id
}

# *** ROUTE TINH VE INGRESS VPC ***
#
# Doc 17 QT2. Thieu dong nay: goi tra loi cua app gui cho NLB o
# ingress VPC (dich 10.0.0.0/16) khong khop route nao khac nen roi
# vao 0.0.0.0/0 va bi day sang EGRESS VPC.
#
# Trieu chung cuc kho doan: request vao toi app, log app cho thay
# xu ly xong va tra 200, nhung client ngoi cho tan timeout.
resource "aws_ec2_transit_gateway_route" "security_to_ingress" {
  count    = local.fw == 1 && var.enable_ingress_route ? 1 : 0
  provider = aws.network

  destination_cidr_block         = var.ingress_vpc_cidr
  transit_gateway_attachment_id  = var.ingress_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security[0].id

  lifecycle {
    precondition {
      condition     = var.ingress_attachment_id != ""
      error_message = "enable_ingress_route = true nhung ingress_attachment_id rong. Route se tro vao hu khong."
    }
  }
}

# Doc 17 QT4: moi VPC khac trong network account can mot dong o day.
resource "aws_ec2_transit_gateway_route" "security_extra" {
  for_each = local.fw == 1 ? var.extra_security_routes : {}
  provider = aws.network

  destination_cidr_block         = each.key
  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security[0].id
}

# Chi nhung gi con lai - Internet that - moi ra egress VPC.
# Dat SAU cac route tinh o tren vi route dai hon luon thang.
resource "aws_ec2_transit_gateway_route" "security_to_egress" {
  count    = local.fw
  provider = aws.network

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security[0].id
}

########################################
# rtb-egress
#
# Goi tra ve tu NAT phai QUAY LAI security VPC de firewall thay du
# ca hai chieu cua phien. Route tinh, khong propagate.
########################################

resource "aws_ec2_transit_gateway_route_table_association" "egress" {
  count    = local.enabled ? 1 : 0
  provider = aws.network

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress[0].id
}

resource "aws_ec2_transit_gateway_route" "egress_return_to_security" {
  count    = local.fw
  provider = aws.network

  destination_cidr_block         = var.internal_supernet
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.security[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress[0].id
}

########################################
# KIEM TRA CHEO
########################################

check "spokes_wired" {
  assert {
    condition     = !local.enabled || length(var.spoke_attachments) > 0
    error_message = "enable = true nhung spoke_attachments rong. Hub dung day va khong spoke nao di qua duoc. Xem muc 3 trong output next_steps."
  }
}

check "firewall_not_silently_off" {
  assert {
    condition     = !local.enabled || var.enable_firewall
    error_message = "enable_firewall = false: spoke di THANG sang egress, khong thanh tra va KHONG cach ly east-west. Doc 17 R8 goi day la rang buoc manh nhat cua thiet ke - tat no la doi kien truc, khong phai tiet kiem."
  }
}

check "single_az_is_not_ha" {
  assert {
    condition     = !local.enabled || length(var.availability_zones) >= 2
    error_message = "Chi mot AZ: AZ do hong la CA landing zone mat duong ra Internet va mat east-west. Chap nhan duoc khi thu code (tiet kiem ~285 USD/thang tien firewall endpoint), khong chap nhan duoc o moi truong that."
  }
}
