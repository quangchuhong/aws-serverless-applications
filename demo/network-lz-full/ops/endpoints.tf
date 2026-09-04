########################################
# INTERFACE ENDPOINT TAP TRUNG - THEM/BOT DICH VU
#
# Layer cha tao bo TOI THIEU (ssm, ssmmessages, ec2messages): thieu ba
# cai do thi khong vao duoc instance nao, ke ca de sua nhung thu khac.
# Chung la ha tang, khong phai lua chon van hanh.
#
# Moi dich vu THEM vao sau do - kms, secretsmanager, ecr, logs - la
# viec van hanh: mot doi noi ho can, co nguoi duyet, va co the bo di
# khi khong dung nua. Chung nam o day.
#
# BON THU PHAI DUNG CUNG LUC thi mot endpoint moi thuc su hoat dong:
#
#   1. aws_vpc_endpoint          ENI trong security VPC
#   2. aws_route53_zone          PHZ de te ten dich vu ve ENI do
#   3. aws_route53_record        ban ghi alias trong PHZ
#   4. profiles_resource_assoc   dua PHZ vao Route 53 Profile
#
# Thieu (4) thi endpoint chay dung o account nay va KHONG account nao
# khac phan giai duoc. Trieu chung tu account spoke: `dig kms.<region>
# .amazonaws.com` ra IP CONG KHAI, va moi loi goi KMS di vong ra
# Internet qua NAT - van chay, van dung, chi la ban dang tra tien cho
# mot endpoint khong ai dung va tra them tien NAT cho luu luong dang
# le khong ra ngoai.
#
# Do la kieu hong khong bao gio bao loi. Ca bon resource duoi day sinh
# tu cung mot dong YAML de khong ai quen cai thu tu.
########################################

locals {
  endpoints = {
    for e in local.endpoints_raw : try(e.service, "khong-co-ten") => {
      service = try(e.service, "")
      ticket  = try(e.ticket, "chua co")
      note    = try(e.note, "")

      # Mot so dich vu can ca ban ghi dai dien:
      #   ecr.dkr    ten repository nam o tien to
      #   logs       khong can
      #
      # Bat khi khong chac: mot ban ghi dai dien thua thi vo hai, con
      # thieu no thi mot nua so loi goi di ra Internet con nua kia thi
      # khong - kieu chap chon rat kho lan.
      wildcard = try(e.wildcard, false)
    }
  }

  # Dich vu layer cha da tao. Tao lai la hai bo ENI, hai hoa don, va
  # hai PHZ cung ten - Route 53 chi tra loi bang MOT trong hai, va no
  # khong noi la cai nao.
  vpce_duplicate = [
    for k, v in local.endpoints : k
    if contains(local.hub.endpoints.managed_services, k)
  ]

  # Ten DNS cua dich vu. Khong phai dich vu nao cung theo mau nay
  # (vi du s3 co dang khac), nhung moi dich vu trong catalog mac dinh
  # deu la interface endpoint chuan.
  vpce_domain = { for k, v in local.endpoints : k => "${k}.${local.hub.region}.amazonaws.com" }
}

########################################
# 1. ENI
########################################

resource "aws_vpc_endpoint" "ops" {
  for_each = local.endpoints

  vpc_id            = local.hub.endpoints.vpc_id
  service_name      = "com.amazonaws.${local.hub.region}.${each.key}"
  vpc_endpoint_type = "Interface"

  # MOT ENI MOI AZ. Dat mot AZ thi endpoint chet theo AZ do va moi
  # spoke mat dich vu cung luc - ke ca spoke o AZ con song.
  subnet_ids         = local.hub.endpoints.subnet_ids
  security_group_ids = [local.hub.endpoints.security_group_id]

  # Tu quan PHZ, giong layer cha. private_dns_enabled = true chi phuc
  # vu VPC chua endpoint, khong voi toi spoke o account khac duoc.
  private_dns_enabled = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "*"
      Resource  = "*"
      Condition = {
        StringEquals = {
          "aws:PrincipalAccount" = local.hub.account_id
        }
      }
    }]
  })

  tags = {
    Name   = "${local.hub.project}-vpce-${each.key}"
    Ticket = each.value.ticket
  }
}

########################################
# 2. PHZ
########################################

resource "aws_route53_zone" "ops_endpoint" {
  for_each = local.endpoints

  name    = local.vpce_domain[each.key]
  comment = "${local.hub.project} PHZ cho VPC endpoint ${each.key} (ops)"

  # Zone PHAI gan it nhat mot VPC luc tao
  vpc {
    vpc_id = local.hub.endpoints.vpc_id
  }

  # Gan thang vao spoke LOCAL - chi khi khong dung Profile.
  # Spoke remote thi khong co duong nao khac ngoai Profile.
  dynamic "vpc" {
    for_each = local.hub.dns.profile_enabled ? {} : {
      for k, v in local.hub.spokes : k => v if v.is_local && v.vpc_id != null
    }
    content {
      vpc_id = vpc.value.vpc_id
    }
  }

  # Association them tu NGOAI state nay - qua Profile, hoac tay tu
  # account khac. Khong bo qua thi moi lan apply Terraform lai go
  # chung ra, va cac account do mat phan giai ten ma khong ai cham
  # vao chung.
  lifecycle {
    ignore_changes = [vpc]
  }
}

########################################
# 3. Ban ghi alias
########################################

resource "aws_route53_record" "ops_endpoint_apex" {
  for_each = local.endpoints

  zone_id = aws_route53_zone.ops_endpoint[each.key].zone_id
  name    = local.vpce_domain[each.key]
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.ops[each.key].dns_entry[0]["dns_name"]
    zone_id                = aws_vpc_endpoint.ops[each.key].dns_entry[0]["hosted_zone_id"]
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "ops_endpoint_wildcard" {
  for_each = { for k, v in local.endpoints : k => v if v.wildcard }

  zone_id = aws_route53_zone.ops_endpoint[each.key].zone_id
  name    = "*.${local.vpce_domain[each.key]}"
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.ops[each.key].dns_entry[0]["dns_name"]
    zone_id                = aws_vpc_endpoint.ops[each.key].dns_entry[0]["hosted_zone_id"]
    evaluate_target_health = false
  }
}

########################################
# 4. Dua PHZ vao Route 53 Profile
#
# BUOC HAY BI QUEN NHAT trong ca bon. Ba buoc tren deu tao ra thu
# nhin thay duoc trong console cua account nay; buoc nay la thu duy
# nhat lam cho account KHAC thay.
########################################

resource "aws_route53profiles_resource_association" "ops_endpoint" {
  for_each = local.hub.dns.profile_enabled ? local.endpoints : {}

  name         = "ops-endpoint-${each.key}"
  profile_id   = local.hub.dns.profile_id
  resource_arn = aws_route53_zone.ops_endpoint[each.key].arn
}

########################################
# KIEM TRA CHEO
########################################

# Co endpoint nhung Profile dang tat VA co spoke o account khac.
#
# Truong hop nay khong bao loi o dau: endpoint chay, PHZ chay, spoke
# local dung tot. Chi cac account khac la khong thay gi, va chung
# khong bao vi chung van co duong ra Internet de goi dich vu do.
check "endpoints_reach_remote_accounts" {
  assert {
    condition = (
      length(local.endpoints) == 0
      || local.hub.dns.profile_enabled
      || alltrue([for k, v in local.hub.spokes : v.is_local])
    )
    error_message = "Co ${length(local.endpoints)} endpoint trong catalog va co spoke o ACCOUNT KHAC, nhung Route 53 Profile dang tat. Cac account do se phan giai ten dich vu ra IP CONG KHAI va di vong ra Internet qua NAT: van chay, nhung endpoint thi khong ai dung va tien NAT thi van tra."
  }
}

check "endpoints_have_an_owner" {
  assert {
    condition     = alltrue([for k, v in local.endpoints : v.ticket != "chua co"])
    error_message = "Co endpoint khong khai ticket. Moi endpoint la ~$0.01/gio moi AZ - khong ai nho da bat cho ai thi khong ai dam tat."
  }
}
