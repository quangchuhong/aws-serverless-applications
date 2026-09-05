########################################
# VAN HANH KET NOI DOI TAC
#
# DUONG HAM KHONG NAM O DAY. VPN connection, customer gateway, VGW,
# private NAT, ban than con NLB - tat ca o ../partner.tf, va chung doi
# vai thang mot lan.
#
# Cai doi HANG TUAN la: doi tac nao duoc goi DICH VU nao, cong nao,
# den bao gio. Lop nay so huu dung nhung thu do:
#
#   target group      mot cai moi dich vu cong bo
#   target            dia chi that cua ung dung, giai TU TEN
#   listener          mot cong tren NLB cua doi tac
#   route VPN         dai phu doi tac cong bo them
#   canh bao          duong ham tut xuong thi co nguoi biet
#
# --------------------------------------------------------------
# VI SAO TACH RA KHOI LAYER CHA
#
# Cong bo mot dich vu moi cho doi tac la ba dong YAML. Neu ba dong do
# nam trong layer cha thi moi lan them mot dich vu la mot plan tren
# ~200 resource, va nguoi duyet phai doc het de tim ra ba dong that su
# doi. Sau vai lan, khong ai doc nua - ho nhin so cuoi va bam yes.
#
# O day plan chi co dung nhung thu vua them.
#
# --------------------------------------------------------------
# GIOI HAN KHONG THE VUOT: MOT CONG, MOT LISTENER
#
# NLB khong cho hai listener cung mot cong. Layer cha da chiem
# reserved_port cho dich vu demo, va hai dich vu trong catalog cham
# nhau cung hong y het.
#
# Ca hai truong hop deu bi chan o precondition ben duoi, chu khong
# phai o giua apply - vi o giua apply thi mot nua so target group da
# duoc tao va ban phai don tay.
########################################

locals {
  partner_on = try(local.hub.partner.enabled, false)

  ########################################
  # DANH SACH DICH VU - phang tu (doi tac x dich vu)
  #
  # Khoa la "<doi tac>-<dich vu>". Khoa nay di vao ten target group va
  # vao dia chi cua resource trong state, nen doi ten mot dich vu se
  # thay no - dung nhu doi ten mot app. Chap nhan duoc, va no bat
  # nguoi ta dat ten mot lan cho dung.
  ########################################

  # concat([{}], ...) chu khong phai merge([...]...) tran.
  #
  # Voi partners.yaml rong, cach viet tran thanh merge() KHONG THAM SO
  # va Terraform bao "Not enough function arguments" - mot loi noi ve
  # so tham so cua ham, khong noi gi ve catalog rong. Ma catalog rong
  # la trang thai MAC DINH cua repo nay.
  partner_services = merge(concat([{}], [
    for p in local.partners_raw : {
      for s in try(p.services, []) :
      "${try(p.name, "khong-ten")}-${try(s.name, "khong-ten")}" => {
        partner = try(p.name, "khong-ten")
        service = try(s.name, "khong-ten")
        port    = try(tonumber(s.port), 0)
        target  = try(s.target, "(thieu target)")

        # Dia chi that cua ung dung, giai theo thu tu:
        #
        #   1. target_ip khai tay      - loi thoat, khi app khong phai mot may
        #   2. app trong apps.yaml     - CHI khi cidr cua no la mot dia chi /32
        #
        # NLB can MOT dia chi, khong phai mot dai. App khai spoke ca
        # /16 thi khong giai duoc thanh target, va do la loi to chu
        # khong phai mot lua chon mac dinh nao do - precondition o
        # main.tf noi ro hai cach sua.
        target_ip = try(s.target_ip, null) != null ? tostring(s.target_ip) : try(
          regex("^([0-9.]+)/32$", local.apps[try(s.target, "")].cidr)[0],
          null,
        )

        # Ke thua tu ho so doi tac khi dich vu khong khai rieng. Mot
        # dich vu cua doi tac khong the song lau hon hop dong.
        ticket = try(s.ticket, try(p.ticket, "chua khai"))
        note   = try(s.note, "")

        # substr(..., 0, 10) - CAT VE DUNG NGAY, giong firewall.tf:53.
        #
        # yamldecode doc `expires: 2026-12-31` khong ra chuoi ma ra mot
        # moc thoi gian, va tostring() cua no la
        # "2026-12-31T00:00:00Z". Phep so sanh van dung vi no cat 10 ky
        # tu dau, nhung phan HIEN THI thi khong: the tag cua target
        # group va ban van dua cho doi tac deu in ca duoi "T00:00:00Z".
        #
        # Cai thu hai moi la van de - do la thu dan vao email gui ra
        # ngoai cong ty.
        expires = try(s.expires, try(p.expires, null)) == null ? null : substr(
          tostring(try(s.expires, p.expires)), 0, 10
        )
      }
    }
  ])...)

  # Ngay het han thanh so, cung cach voi rule firewall.
  #
  # Khong co ngay = 99991231, KHONG phai null: `&&` trong HCL khong
  # short-circuit nen mot null lot vao day se no o ve phai. Xem loi 71.
  partner_service_expiry = {
    for k, s in local.partner_services : k => (
      s.expires == null ? 99991231 : tonumber(
        replace(substr(tostring(s.expires), 0, 10), "-", "")
      )
    )
  }

  ########################################
  # DAI PHU DOI TAC CONG BO THEM
  #
  # remote_cidr trong ho so PHAI khop dai layer cha dinh tuyen - do la
  # hop dong, va precondition o main.tf giu no.
  #
  # Nhung mot doi tac co the cong bo THEM dai theo thoi gian: ho mo
  # thi mot trung tam du lieu thu hai, doi nha cung cap, tach mang.
  # Do la thay doi hang thang, khong phai thay doi kien truc - nen no
  # thuoc ve day.
  #
  # LOAI dai cha da so huu ra khoi danh sach. Khai lai thi AWS tu choi
  # o giua apply voi mot ma loi khong noi gi ve viec route do thuoc
  # layer khac - cung hinh dang voi bang loai tru trong routes.tf.
  ########################################

  partner_extra_cidrs = distinct([
    for c in flatten([
      for p in local.partners_raw : try(p.extra_cidrs, [])
    ]) : c if c != try(local.hub.partner.remote_cidr, "")
  ])

  ########################################
  # PHEP KIEM - tinh o day, khang dinh o main.tf
  ########################################

  # Cong cham vao cai layer cha da chiem
  partner_port_reserved = [
    for k, s in local.partner_services : k
    if s.port == try(local.hub.partner.reserved_port, -1)
  ]

  # Hai dich vu cung mot cong - NLB chi cho mot listener moi cong
  partner_port_dup = [
    for k, s in local.partner_services : k
    if length([for k2, s2 in local.partner_services : k2 if s2.port == s.port]) > 1
  ]

  partner_port_bad = [
    for k, s in local.partner_services : k
    if s.port < 1 || s.port > 65535
  ]

  # Target khong giai duoc thanh MOT dia chi
  partner_target_unresolved = [
    for k, s in local.partner_services : k if s.target_ip == null
  ]

  # Target tro toi mot app khong co trong apps.yaml
  partner_target_unknown = [
    for k, s in local.partner_services : k
    if try(s.target_ip, null) == null && !contains(keys(local.apps), s.target)
  ]

  # Ten target group qua dai. AWS gioi han 32 ky tu, va cat bot thi hai
  # dich vu ten gan giong nhau se cham ten nhau - hong o giua apply.
  partner_tg_name_long = [
    for k, s in local.partner_services : k
    if length("${local.hub.project}-p-${k}") > 32
  ]

  partner_service_expired = [
    for k, s in local.partner_services : k
    if local.partner_service_expiry[k] < local.today_num
  ]

  partner_service_soon = [
    for k, s in local.partner_services : k
    if local.partner_service_expiry[k] >= local.today_num
    && local.partner_service_expiry[k] <= local.soon_num
  ]
}

########################################
# TARGET GROUP - mot cai moi dich vu
#
# target_type = "ip" va target nam NGOAI 3rd-party VPC: ung dung that
# o spoke, o mot account khac, cach day mot TGW va mot firewall.
#
# Do la ca diem cua kien truc nay. Doi tac ket noi toi NLB trong vung
# dem; NLB mo mot ket noi MOI toi spoke. Hai ket noi tach roi, va dia
# chi that cua spoke khong bao gio xuat hien phia ben kia duong ham.
########################################

resource "aws_lb_target_group" "partner_service" {
  for_each = local.partner_on ? local.partner_services : {}

  name        = "${local.hub.project}-p-${each.key}"
  port        = each.value.port
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = local.hub.partner.vpc_id

  health_check {
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = {
    Name    = "${local.hub.project}-p-${each.key}"
    Partner = each.value.partner
    Service = each.value.service
    Ticket  = each.value.ticket
    Expires = each.value.expires == null ? "khong" : tostring(each.value.expires)
  }
}

# availability_zone = "all" LA BAT BUOC.
#
# Target nam ngoai VPC cua NLB, nen NLB khong suy ra duoc no o AZ nao.
# Thieu dong nay, AWS tu choi voi mot thong bao noi ve AZ - khong noi
# rang van de la target o ngoai VPC.
resource "aws_lb_target_group_attachment" "partner_service" {
  for_each = local.partner_on ? local.partner_services : {}

  target_group_arn  = aws_lb_target_group.partner_service[each.key].arn
  target_id         = each.value.target_ip
  port              = each.value.port
  availability_zone = "all"
}

########################################
# LISTENER - mot cong tren NLB cua doi tac
#
# Day la thu doi tac THAT SU cham vao. Them mot listener la mo them
# mot cua; go no di la dong cua do ngay lap tuc, ke ca khi rule
# firewall van con.
#
# Hai lop, hai cau hoi khac nhau:
#   listener   doi tac GOI DUOC toi dau
#   firewall   goi tin co DI TIEP duoc toi spoke khong
#
# Go mot trong hai la du de cat. Giu ca hai la de mot sai sot o mot
# lop khong tu no mo duong.
########################################

resource "aws_lb_listener" "partner_service" {
  for_each = local.partner_on ? local.partner_services : {}

  load_balancer_arn = local.hub.partner.nlb_arn
  port              = each.value.port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.partner_service[each.key].arn
  }
}

########################################
# ROUTE VPN - dai phu doi tac cong bo
#
# Voi static_routes_only = true o layer cha, day la CACH DUY NHAT VGW
# biet mot dai nam sau duong ham. Thieu no thi duong ham UP, goi tin
# di mot chieu, va khong co gi bao - xem lai lop cach ly o doc 16.
########################################

resource "aws_vpn_connection_route" "partner_extra" {
  for_each = local.partner_on ? toset(local.partner_extra_cidrs) : toset([])

  vpn_connection_id      = local.hub.partner.vpn_connection_id
  destination_cidr_block = each.value
}

########################################
# CANH BAO DUONG HAM
#
# VI SAO PHAI CO
#
# Duong ham tut xuong khong sinh ra su kien git nao, khong lam plan
# doi, khong lam verify.sh do - tru khi co nguoi chay no. Doi tac se
# la nguoi phat hien ra, va ho phat hien bang mot cuoc goi dien.
#
# TunnelState: 0 = down, 1 = up. Voi hai duong ham, Average cua ca
# VPN connection cho ba muc:
#
#   1.0   ca hai len
#   0.5   mot len - VAN CHAY, nhung da mat du phong
#   0.0   dut han
#
# Hai muc canh bao vi hai muc do doi hai hanh dong khac nhau. Gop lam
# mot thi hoac bo qua trang thai mat du phong, hoac keu to moi lan
# AWS bao tri mot duong ham - va kieu thu hai thi sau vai lan khong
# ai doc nua.
########################################

resource "aws_cloudwatch_metric_alarm" "partner_vpn_down" {
  count = local.partner_on && try(local.hub.partner.vpn_connection_id, null) != null ? 1 : 0

  alarm_name        = "${local.hub.project}-partner-vpn-DUT"
  alarm_description = "Ca hai duong ham VPN toi doi tac deu xuong. Ket noi da dut hoan toan."

  namespace   = "AWS/VPN"
  metric_name = "TunnelState"
  dimensions  = { VpnId = local.hub.partner.vpn_connection_id }

  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 0.5

  # Thieu du lieu = coi nhu DUT.
  #
  # Mac dinh cua CloudWatch la "missing" - tuc canh bao khong keu.
  # Nhung mot VPN connection ngung phat metric la mot tin xau, khong
  # phai mot tin trung tinh.
  treat_missing_data = "breaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = { Name = "${local.hub.project}-partner-vpn-DUT" }
}

resource "aws_cloudwatch_metric_alarm" "partner_vpn_degraded" {
  count = local.partner_on && try(local.hub.partner.vpn_connection_id, null) != null ? 1 : 0

  alarm_name        = "${local.hub.project}-partner-vpn-mat-du-phong"
  alarm_description = "Mot trong hai duong ham VPN toi doi tac dang xuong. Ket noi VAN CHAY nhung khong con du phong."

  namespace   = "AWS/VPN"
  metric_name = "TunnelState"
  dimensions  = { VpnId = local.hub.partner.vpn_connection_id }

  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "LessThanThreshold"
  threshold           = 1

  # Khac cai tren: thieu du lieu KHONG keu o day. Muc "dut han" da lo
  # truong hop do roi, va keu hai lan cho cung mot su co la cach nhanh
  # nhat de nguoi ta tat ca hai.
  treat_missing_data = "notBreaching"

  alarm_actions = var.alarm_actions

  tags = { Name = "${local.hub.project}-partner-vpn-mat-du-phong" }
}
