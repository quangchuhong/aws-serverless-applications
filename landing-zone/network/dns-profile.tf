########################################
# ROUTE 53 PROFILE - DNS TAP TRUNG CHO ACCOUNT KHAC
#
# Van de: mot PHZ nam trong account network. Spoke o account khac
# phai phan giai duoc ten trong do - ten noi bo, va ten dich vu AWS
# tro vao interface endpoint tap trung.
#
# ---------------------------------------------------------------
# HAI CACH, VA VI SAO CHON CACH NAY
#
# KHONG Profile: moi cap (zone, VPC) can mot lien ket rieng, va lien
#   ket cross-account can HAI lenh o HAI account:
#
#     aws route53 create-vpc-association-authorization   (ben zone)
#     aws route53 associate-vpc-with-hosted-zone         (ben VPC)
#
#   4 zone x 20 account = 160 lenh, va moi account moi la 8 lenh nua.
#   Output `paste_endpoint_dns` van giu cach nay cho ai can lam tay.
#
# CO Profile: gan N zone vao profile MOT LAN, share profile qua RAM
#   mot lan, roi moi VPC gan vao profile bang MOT resource - va
#   resource do nam trong template CloudFormation cua chinh spoke,
#   tuc no chay o account so huu VPC.
#
# Cach thu hai la duong DUY NHAT tu dong hoa duoc, vi buoc cuoi chay
# duoc o account workload thay vi phai quay lai account network.
#
# ---------------------------------------------------------------
# SHARE RIENG, KHONG GHEP VAO SHARE CUA TGW
#
# Ghep chung mot resource share co hai cai loi:
#
#   1. Account nao duoc TGW la duoc luon DNS profile. Hai thu do
#      khong nhat thiet cung tap account - mot account co the can
#      DNS noi bo ma khong can noi TGW.
#   2. Go mot thu la dong ca hai. Thu hoi quyen DNS cua mot account
#      khong nen keo theo viec no mat duong mang.
########################################

resource "aws_route53profiles_profile" "shared" {
  count    = local.enabled && var.enable_dns_profile ? 1 : 0
  provider = aws.network

  name = "${var.project}-dns-profile"

  tags = { Name = "${var.project}-dns-profile" }
}

# PHZ cua tung interface endpoint vao profile.
#
# Day la phan lam cho endpoint TAP TRUNG co nghia: khong co chung,
# ssm.<region>.amazonaws.com o spoke phan giai ra IP CONG KHAI, luu
# luong di vong ra Internet qua NAT, va interface endpoint van tinh
# tien ma khong ai dung. Tien mat ma khong ai thay - kieu lang phi
# kho phat hien nhat.
resource "aws_route53profiles_resource_association" "endpoints" {
  for_each = local.enabled && var.enable_dns_profile ? aws_route53_zone.endpoint : {}
  provider = aws.network

  name         = "${var.project}-${each.key}"
  profile_id   = aws_route53profiles_profile.shared[0].id
  resource_arn = each.value.arn
}

resource "aws_ram_resource_share" "dns_profile" {
  count    = local.enabled && var.enable_dns_profile && var.share_tgw_with_org ? 1 : 0
  provider = aws.network

  name                      = "${var.project}-dns-profile"
  allow_external_principals = false

  tags = { Name = "${var.project}-dns-profile-share" }
}

resource "aws_ram_resource_association" "dns_profile" {
  count    = local.enabled && var.enable_dns_profile && var.share_tgw_with_org ? 1 : 0
  provider = aws.network

  resource_arn       = aws_route53profiles_profile.shared[0].arn
  resource_share_arn = aws_ram_resource_share.dns_profile[0].arn
}

resource "aws_ram_principal_association" "dns_profile_org" {
  count    = local.enabled && var.enable_dns_profile && var.share_tgw_with_org ? 1 : 0
  provider = aws.network

  principal          = data.aws_organizations_organization.this.arn
  resource_share_arn = aws_ram_resource_share.dns_profile[0].arn
}

########################################
# KIEM TRA CHEO
########################################

check "dns_profile_has_something_in_it" {
  assert {
    condition = (
      !local.enabled
      || !var.enable_dns_profile
      || var.enable_interface_endpoints
    )
    error_message = "enable_dns_profile = true nhung enable_interface_endpoints = false: profile duoc tao, duoc share, va KHONG CO ZONE NAO trong do. Spoke gan vao no thanh cong va khong phan giai duoc gi them - dung kieu hong khong bao loi."
  }
}

check "dns_profile_is_shared" {
  assert {
    condition = (
      !local.enabled
      || !var.enable_dns_profile
      || var.share_tgw_with_org
    )
    error_message = "enable_dns_profile = true nhung share_tgw_with_org = false: profile chi dung duoc trong chinh account nay. Account workload khong nhin thay no, va StackSet cua account-baseline se hong o buoc gan profile."
  }
}
