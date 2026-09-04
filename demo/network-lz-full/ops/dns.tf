########################################
# BAN GHI TRONG PHZ TAP TRUNG
#
# Zone do layer cha so huu. Lop nay chi them ban ghi VAO trong no -
# khong tao, khong xoa, khong doi thuoc tinh cua zone.
#
# Nho vay mot lan apply sai o day, xau nhat, la mot cai ten tro nham
# cho. Khong lan nao xoa duoc ca zone.
#
# VI SAO PHAI QUAN O DAY thay vi de moi doi tu tao ban ghi trong
# account cua ho: PHZ nay gan vao MOI VPC cua landing zone qua Route
# 53 Profile. Mot ban ghi trong no hien ra o ca nam account. Do la
# khong gian ten CHUNG, va khong gian ten chung ma khong co mot cho
# duy nhat de doc thi se co hai doi dat trung ten - roi ca hai deu
# thay DNS "chap chon" trong khi tra loi luon nhat quan voi ban ghi
# thang cuoi cung ghi de.
########################################

locals {
  # Ten zone doi khi mang dau cham cuoi tuy nguon doc. Cat di de ghep
  # ten khong ra "app..lz.internal" - mot loi chi hien ra o dig, khong
  # hien o plan.
  zone_name = trimsuffix(try(local.hub.dns.zone_name, ""), ".")

  dns_records = {
    for r in local.dns_raw : try(r.name, "khong-co-ten") => {
      name   = try(r.name, "")
      type   = upper(try(r.type, "A"))
      ttl    = try(r.ttl, 60)
      values = try(r.values, [])
      ticket = try(r.ticket, "chua co")
      note   = try(r.note, "")

      allow_external = try(r.allow_external, false)

      # "@" = chinh zone. Hiem dung nhung phai co, neu khong thi cach
      # duy nhat de dat ban ghi apex la go tay ca ten mien - va no se
      # sai vao ngay ai do doi internal_dns_domain.
      fqdn = try(r.name, "") == "@" ? local.zone_name : "${try(r.name, "")}.${local.zone_name}"
    }
  }

  ########################################
  # KIEM TRA
  ########################################

  # Trung ten voi ban ghi cua layer cha.
  #
  # Kieu hong te nhat trong ca lop nay, vi CA HAI PLAN DEU SACH. Hai
  # aws_route53_record cung ten nam trong hai state khac nhau: moi
  # state tin rang no so huu ban ghi do, moi lan apply mot ben la ghi
  # de ben kia, va khong ben nao thay diff. Ten do se nhay qua nhay
  # lai theo thu tu ai chay sau.
  dns_collide = [
    for k, v in local.dns_records : v.fqdn
    if contains([for n in local.hub.dns.managed_records : trimsuffix(n, ".")], v.fqdn)
  ]

  dns_bad_type = [
    for k, v in local.dns_records : "${k} (${v.type})"
    if !contains(["A", "AAAA", "CNAME", "TXT", "SRV"], v.type)
  ]

  # Ban ghi A tro ra ngoai landing zone.
  #
  # PHZ noi bo che mat ten that doi voi MOI VPC duoc gan. Mot ban ghi
  # A tro ra IP cong khai o day gan nhu luon la go nham mot dai dia
  # chi - va neu khong phai, no van dang keo mot ten cong khai vao
  # trong khong gian ten rieng cua ca to chuc.
  # try() bao ca bieu thuc: && khong short-circuit trong HCL, nen
  # can() o ve trai khong ngan cidrhost o ve phai chay tren mot gia
  # tri khong phai IP.
  #
  # Gia tri khong doc duoc -> false -> ban ghi bi bao la tro ra ngoai.
  # Dung huong: lint.sh da bat rieng "gia tri khong phai IPv4", va o
  # day thi mot gia tri kho hieu KHONG nen duoc coi la noi bo.
  dns_external_ip = [
    for k, v in local.dns_records : k
    if v.type == "A" && !v.allow_external && !alltrue([
      for ip in v.values : try(
        cidrhost(
          "${ip}/${split("/", local.hub.internal_supernet)[1]}", 0
        ) == cidrhost(local.hub.internal_supernet, 0),
        false,
      )
    ])
  ]
}

resource "aws_route53_record" "ops" {
  for_each = local.dns_records

  zone_id = local.hub.dns.zone_id
  name    = each.value.fqdn
  type    = each.value.type
  ttl     = each.value.ttl
  records = [for v in each.value.values : tostring(v)]

  lifecycle {
    precondition {
      condition     = length(each.value.values) > 0
      error_message = "dns-records.yaml: ban ghi '${each.key}' khong co values. Mot ban ghi rong khong phai la xoa - no la mot loi API."
    }

    # TTL cao tren mot ten dang duoc doi la thu bien mot thao tac hai
    # phut thanh mot su co mot tieng: doi xong roi van phai cho cache
    # het han o moi resolver trong moi VPC.
    precondition {
      condition     = each.value.ttl >= 30 && each.value.ttl <= 86400
      error_message = "dns-records.yaml: ttl cua '${each.key}' la ${each.value.ttl}. Dung trong khoang 30..86400. Ten hay doi thi de 60; ten on dinh thi de cao hon de bot truy van."
    }
  }
}

########################################
# KIEM TRA CHEO
########################################

check "dns_records_have_an_owner" {
  assert {
    condition     = alltrue([for k, v in local.dns_records : v.ticket != "chua co"])
    error_message = "Co ban ghi DNS khong khai ticket. Ten trong PHZ tap trung hien ra o moi account - khong biet ai dat thi khong ai dam go."
  }
}

# Zone nay co toi duoc account khac khong.
#
# Voi spoke o account khac, PHZ chi toi noi qua Route 53 Profile. Tat
# Profile thi ban ghi van tao thanh cong va van doc duoc TU ACCOUNT
# NAY - nen moi phep thu tai cho deu xanh, trong khi bon account kia
# khong phan giai duoc gi.
check "dns_reaches_remote_accounts" {
  assert {
    condition = (
      length(local.dns_records) == 0
      || local.hub.dns.profile_enabled
      || alltrue([for k, v in local.hub.spokes : v.is_local])
    )
    error_message = "Co ban ghi DNS va co spoke o ACCOUNT KHAC, nhung Route 53 Profile dang tat. Ban ghi chi phan giai duoc tu cac VPC trong chinh account nay. Kiem tra tu account kia, dung tu day."
  }
}
