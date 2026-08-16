########################################
# Transit Gateway
# Ban than TGW khong tinh phi theo gio - chi phi nam o ATTACHMENT.
########################################

resource "aws_ec2_transit_gateway" "hub" {
  description = "${var.project} hub"

  # Tat route table mac dinh de tu quan ly - day la diem quan trong.
  # De mac dinh thi moi attachment tu dong thay nhau, mat cach ly spoke.
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"

  tags = { Name = "${var.project}-tgw" }
}

########################################
# Ba route table, ba vai tro
########################################

resource "aws_ec2_transit_gateway_route_table" "spokes" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "${var.project}-rtb-spokes" }
}

resource "aws_ec2_transit_gateway_route_table" "egress" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "${var.project}-rtb-egress" }
}

resource "aws_ec2_transit_gateway_route_table" "ingress" {
  count              = var.enable_ingress ? 1 : 0
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "${var.project}-rtb-ingress" }
}

########################################
# Attachment
########################################

resource "aws_ec2_transit_gateway_vpc_attachment" "egress" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.egress.id
  subnet_ids         = [aws_subnet.egress_tgw.id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-tgwa-egress" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "ingress" {
  count = var.enable_ingress ? 1 : 0

  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.ingress[0].id
  subnet_ids         = [aws_subnet.ingress_tgw[0].id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-tgwa-ingress" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "spoke" {
  for_each = var.spokes

  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.spoke[each.key].id
  subnet_ids         = [aws_subnet.spoke_tgw[each.key].id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-tgwa-${each.key}" }
}

########################################
# Association: attachment nay dung route table nao
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

resource "aws_ec2_transit_gateway_route_table_association" "ingress" {
  count = var.enable_ingress ? 1 : 0

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.ingress[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.ingress[0].id
}

########################################
# Propagation: route table nay hoc duong tu attachment nao
########################################

# Egress hoc duong toi moi spoke (de tra loi ve)
resource "aws_ec2_transit_gateway_route_table_propagation" "spokes_to_egress" {
  for_each = var.spokes

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

# Ingress hoc duong toi moi spoke (de ALB voi toi target)
resource "aws_ec2_transit_gateway_route_table_propagation" "spokes_to_ingress" {
  for_each = var.enable_ingress ? var.spokes : {}

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.ingress[0].id
}

# Spoke hoc duong VE ingress VPC (traffic tra loi ALB)
resource "aws_ec2_transit_gateway_route_table_propagation" "ingress_to_spokes" {
  count = var.enable_ingress ? 1 : 0

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.ingress[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

########################################
# Route tinh: moi spoke ra Internet qua egress VPC
#
# CHU Y: rtb-spokes KHONG propagate tu cac spoke khac.
# Do do app-dev khong route duoc sang app-prod - cach ly spoke-to-spoke.
########################################

resource "aws_ec2_transit_gateway_route" "spokes_default" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}
