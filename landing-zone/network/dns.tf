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
# CHI CO SPOKE LOCAL thi no khong giai gi ca - PHZ gan thang vao ca ba
# VPC da xong, va van tinh phi association. Bat len khi co spoke o
# ACCOUNT KHAC: luc do profile la duong duy nhat mang PHZ sang do ma
# khong ai phai dang nhap vao account kia.
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
# Share profile cho cac account co spoke
#
# Chi co y nghia khi co VPC o account khac.
########################################

# DUNG CHUNG SHARE VOI TRANSIT GATEWAY - co chu y.
#
# Truoc day cho nay tu tao mot share rieng
# (${var.project}-dns-profile) voi principal la organization_arn.
# Duong do KHONG chay: RAM khong phan giai duoc to chuc, nen moi
# principal trong pham vi to chuc deu bi tu choi. Loi 56.
#
# Gan profile vao CHINH share da dung cho TGW co hai cai loi, va cai
# thu hai moi la ly do that:
#
#   1. Mot share = mot loi moi. Account spoke bam nhan MOT lan, nhan
#      duoc ca TGW lan DNS profile.
#   2. Khong the lech nhau. Hai share rieng thi mot account co the da
#      nhan cai nay ma chua nhan cai kia - VPC dung duoc mang nhung
#      phan giai ten sai, mot trang thai nua voi rat kho doc.
#
# Doi lai: ten share ("${var.project}-tgw") gio khong con ta het thu
# no mang. Doi ten se ep tao lai share va moi account phai nhan lai
# loi moi, nen giu nguyen va ghi ro o day.
resource "aws_ram_resource_association" "dns_profile" {
  count = var.enable_dns_profile && local.ram_share == 1 ? 1 : 0

  resource_arn       = aws_route53profiles_profile.shared[0].arn
  resource_share_arn = aws_ram_resource_share.tgw[0].arn
}

########################################
# KIEM TRA CHEO
########################################

check "dns_profile_earns_its_keep" {
  assert {
    condition     = !var.enable_dns_profile || local.has_remote
    error_message = "enable_dns_profile = true nhung khong co spoke nao o account khac: profile chi gan vao cac VPC trong CHINH account nay, ma chung da co PHZ gan thang roi. Dang tra phi association cho mot thu khong lam gi. Khai spoke co account_id, hoac tat profile di."
  }
}

# Profile co ma KHONG share thi account spoke khong thay no, va
# ProfileAssociation trong template CloudFormation se hong voi mot cau
# khong nhac gi toi RAM.
check "dns_profile_reaches_remote_spokes" {
  assert {
    condition     = !var.enable_dns_profile || !local.has_remote || local.ram_share == 1
    error_message = "enable_dns_profile = true va co spoke o account khac, nhung ram_use_external_principals = false nen profile khong duoc share di dau. Stack o account spoke se bao khong tim thay profile."
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
