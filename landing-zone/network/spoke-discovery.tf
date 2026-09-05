########################################
# TU TIM ATTACHMENT CUA ACCOUNT WORKLOAD
#
# Van de: account-baseline tao VPC va TGW attachment o account
# workload. Attachment do hien ra o ACCOUNT NAY - vi day so huu TGW -
# nhung Terraform ben kia khong biet ID cua no, va Terraform ben nay
# khong biet no sap xuat hien.
#
# Khong noi vao route table thi: VPC ton tai, attachment ton tai
# trang thai available, va KHONG CO GOI TIN NAO DI DAU CA. Attachment
# khong nam trong bang nao thi no khong hoc duoc duong nao, va khong
# ai hoc duoc duong toi no.
#
# Trieu chung doc nhu mot loi dinh tuyen o spoke, va nguoi ta se di
# tim trong VPC do - noi khong co gi sai ca.
#
# ---------------------------------------------------------------
# HAI DUONG, DUNG CHUNG MOT DICH
#
#   var.spoke_attachments   khai TAY tung ID. Chinh xac, khong doan
#                           gi, va phai cap nhat moi lan them account
#
#   var.spoke_accounts      khai ACCOUNT ID, layer tu tim moi
#                           attachment cua account do
#
# Duong thu hai la thu lam cho viec them account thanh mot dong
# trong tfvars thay vi mot vong "apply, doc ID, dan lai, apply lai".
#
# ---------------------------------------------------------------
# NO CHAY SAU MOT NHIP, VA DO LA DIEU KHONG TRANH DUOC
#
# data source doc luc PLAN. Lan plan dau tien - truoc khi StackSet
# ben account-baseline tao xong attachment - danh sach RONG, va
# khong co association nao duoc tao.
#
# Nen thu tu that la:
#
#   1. account-baseline apply  -> VPC + attachment duoc tao
#   2. layer nay apply         -> attachment duoc noi vao route table
#
# Chay nguoc lai thi buoc 2 khong lam gi va cung khong bao gi. Output
# `spokes_wired` dem so attachment DA noi - so do lech voi so account
# la dau hieu duy nhat, nen doc no sau moi lan them account.
########################################

data "aws_ec2_transit_gateway_attachments" "by_account" {
  for_each = local.enabled ? toset(var.spoke_accounts) : toset([])
  provider = aws.network

  filter {
    name   = "transit-gateway-id"
    values = [aws_ec2_transit_gateway.hub[0].id]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  # CHI attachment cua VPC. Account workload khong tao VPN hay peering
  # attachment, nhung neu co thi chung KHONG thuoc rtb-spokes.
  filter {
    name   = "resource-type"
    values = ["vpc"]
  }
  filter {
    name   = "resource-owner-id"
    values = [each.value]
  }
}

locals {
  # Khoa la CHINH attachment id, khong phai ten account. Nho vay mot
  # account co hai VPC cung chay dung: moi attachment tim thay duoc
  # noi dung mot lan.
  discovered_attachments = local.enabled ? toset(flatten([
    for d in data.aws_ec2_transit_gateway_attachments.by_account : d.ids
  ])) : toset([])

  # Gop hai duong. Khai tay mot ID ma no cung duoc tim thay thi
  # toset() bo trung - khong sinh ra hai association cho mot
  # attachment, va do la thu AWS se tu choi.
  all_spoke_attachments = toset(concat(
    values(var.spoke_attachments),
    tolist(local.discovered_attachments),
  ))
}

resource "aws_ec2_transit_gateway_route_table_association" "discovered" {
  for_each = local.discovered_attachments
  provider = aws.network

  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes[0].id
}

# Propagate vao rtb-security de luu luong QUAY VE spoke tim duoc
# duong. Thieu dong nay: goi tin di den duoc ung dung, ung dung tra
# loi, va goi tra loi den TGW thi khong co duong ve - mot chieu
# thong, mot chieu khong, va moi phep kiem o chieu di deu xanh.
resource "aws_ec2_transit_gateway_route_table_propagation" "discovered_to_security" {
  for_each = local.fw == 1 ? local.discovered_attachments : toset([])
  provider = aws.network

  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security[0].id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "discovered_to_egress" {
  for_each = local.enabled && !var.enable_firewall ? local.discovered_attachments : toset([])
  provider = aws.network

  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress[0].id
}

########################################
# KIEM TRA CHEO
########################################

check "every_spoke_account_has_an_attachment" {
  assert {
    condition = alltrue([
      for acct, d in data.aws_ec2_transit_gateway_attachments.by_account :
      length(d.ids) > 0
    ])
    error_message = "Co account trong spoke_accounts chua co TGW attachment nao o trang thai available. Hai kha nang: (1) account-baseline chua apply, hoac StackSet cua no chua chay xong - apply ben do truoc; (2) account chua chap nhan loi moi RAM cho TGW, nen no khong tao duoc attachment. Kiem: aws ram get-resource-share-invitations --region ${var.region}"
  }
}
