########################################
# DNS TAP TRUNG - doc 12
#
# Hai thu khac han nhau, dung lan:
#
#   PHZ noi bo        dat ten cho service noi bo. Huu ich NGAY, ke ca
#                     mot account. Mac dinh BAT.
#
#   Route 53 Profile  gom nhieu PHZ lai, share mot lan cho ca to chuc.
#                     Chi dang gia khi VPC nam o ACCOUNT KHAC. Trong
#                     bo mot account nay no gan nhu khong lam gi, va
#                     van tinh phi association. Mac dinh TAT.
########################################

########################################
# PHZ NOI BO
#
# Khong co no thi moi thu goi nhau bang IP, va IP doi moi lan thay
# instance. Co no thi app-prod goi app-dev qua ten, khong quan tam IP.
########################################

resource "aws_route53_zone" "internal" {
  count = var.enable_internal_dns ? 1 : 0

  name          = var.internal_dns_domain
  comment       = "${var.project} PHZ noi bo"
  force_destroy = var.ephemeral

  # Zone PHAI gan it nhat mot VPC luc tao.
  vpc {
    vpc_id = var.enable_firewall ? aws_vpc.security[0].id : aws_vpc.egress.id
  }

  # Gan thang vao spoke - CHI khi khong dung Profile.
  #
  # Dung ca hai duong cho cung mot VPC la thua: Profile da mang zone
  # nay toi VPC do roi. Xem chu thich o phan Profile ben duoi.
  dynamic "vpc" {
    for_each = var.enable_dns_profile ? {} : local.local_spokes
    content {
      vpc_id = aws_vpc.spoke[vpc.key].id
    }
  }
}

# Moi spoke mot ban ghi tro toi EC2 test cua no.
#
# Day cung la thu de verify.sh kiem duoc DNS that su hoat dong:
# curl http://app-dev.<domain> tu trong app-prod.
resource "aws_route53_record" "spoke_app" {
  for_each = var.enable_internal_dns && var.enable_test_instances ? local.local_spokes : {}

  zone_id = aws_route53_zone.internal[0].zone_id
  name    = "${each.key}.${var.internal_dns_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.test[each.key].private_ip]
}

########################################
# ROUTE 53 PROFILE
#
# Bai toan no giai: gan N PHZ vao M VPC o M account.
#
#   Khong Profile : N x M cap lenh, moi cap gom
#                     create-vpc-association-authorization  (ben zone)
#                     associate-vpc-with-hosted-zone        (ben VPC)
#                   3 zone x 5 account = 30 lenh tay.
#
#   Co Profile    : gan N zone vao profile MOT LAN, share qua RAM mot
#                   lan, roi moi VPC mot dong.
#
# TRONG BO NAY (mot account) no khong giai gi ca - PHZ gan thang vao
# ca ba VPC da xong. Bat len chi de:
#   - thu truoc mo hinh se dung khi len multi-account
#   - hoac chuan bi share cho account khac (can organization_arn)
#
# GIOI HAN: mot VPC chi gan duoc MOT Profile. Nen gom het vao mot,
# dung tach theo chu de.
########################################

resource "aws_route53profiles_profile" "shared" {
  count = var.enable_dns_profile ? 1 : 0

  name = "${var.project}-shared-dns"
  tags = { Name = "${var.project}-shared-dns" }
}

# PHZ noi bo vao profile
resource "aws_route53profiles_resource_association" "internal" {
  count = var.enable_dns_profile && var.enable_internal_dns ? 1 : 0

  name         = "internal-phz"
  profile_id   = aws_route53profiles_profile.shared[0].id
  resource_arn = aws_route53_zone.internal[0].arn
}

# Toan bo PHZ cua VPC endpoint vao profile
resource "aws_route53profiles_resource_association" "endpoints" {
  for_each = var.enable_dns_profile ? aws_route53_zone.endpoint : {}

  name         = "endpoint-${each.key}"
  profile_id   = aws_route53profiles_profile.shared[0].id
  resource_arn = each.value.arn
}

# Gan profile vao tung VPC spoke.
#
# O multi-account, DONG NAY la thu account workload tu chay - mot dong
# duy nhat, thay cho N cap lenh CLI.
resource "aws_route53profiles_association" "spoke" {
  for_each = var.enable_dns_profile ? local.local_spokes : {}

  name        = "${var.project}-${each.key}"
  profile_id  = aws_route53profiles_profile.shared[0].id
  resource_id = aws_vpc.spoke[each.key].id
}

########################################
# Share profile cho ca to chuc
#
# Chi co y nghia khi se co VPC o account khac. De organization_arn
# rong thi profile van chay, chi khong share di dau.
########################################

resource "aws_ram_resource_share" "dns" {
  count = var.enable_dns_profile && var.organization_arn != "" ? 1 : 0

  name                      = "${var.project}-dns-profile"
  allow_external_principals = false

  tags = { Name = "${var.project}-dns-profile" }
}

resource "aws_ram_resource_association" "dns_profile" {
  count = var.enable_dns_profile && var.organization_arn != "" ? 1 : 0

  resource_arn       = aws_route53profiles_profile.shared[0].arn
  resource_share_arn = aws_ram_resource_share.dns[0].arn
}

resource "aws_ram_principal_association" "dns_org" {
  count = var.enable_dns_profile && var.organization_arn != "" ? 1 : 0

  principal          = var.organization_arn
  resource_share_arn = aws_ram_resource_share.dns[0].arn
}

########################################
# KIEM TRA CHEO
########################################

check "dns_profile_earns_its_keep" {
  assert {
    condition     = !var.enable_dns_profile || var.organization_arn != ""
    error_message = "enable_dns_profile = true nhung organization_arn rong: profile chi gan vao cac VPC trong CHINH account nay, ma chung da co PHZ gan thang roi. Dang tra phi association cho mot thu khong lam gi. Dien organization_arn de share ra ngoai, hoac tat profile di."
  }
}

check "internal_dns_domain_is_private" {
  assert {
    condition = (
      !var.enable_internal_dns
      || !endswith(var.internal_dns_domain, ".com")
      && !endswith(var.internal_dns_domain, ".net")
      && !endswith(var.internal_dns_domain, ".org")
    )
    error_message = "internal_dns_domain dung duoi TLD cong khai (${var.internal_dns_domain}). PHZ se CHE MAT ten that do voi moi VPC duoc gan - ke ca ten ban khong so huu. Dung duoi rieng (.internal, .lan) hoac mot domain ban that su so huu."
  }
}
