########################################
# ROUTE NGOAI LE TRONG TGW
#
# DOC KY PHAN NAY TRUOC KHI THEM DONG DAU TIEN.
#
# Cau hoi "them route de hai VPC noi duoc voi nhau" co cau tra loi
# la KHONG CAN. Thiet ke o ../tgw.tf dat DUNG MOT dong trong
# rtb-spokes:
#
#   0.0.0.0/0 -> security VPC
#
# Mot dong do phu moi dich: Internet, spoke khac, ingress VPC. Moi goi
# tin roi khoi bat ky spoke nao deu di vao firewall, va tu do TGW
# quyet dinh no di tiep dau. Them mot route spoke-to-spoke o day khong
# mo them ket noi - no TAO MOT DUONG TAT VONG QUA FIREWALL, va do
# dung la thu ca thiet ke nay dung de ngan.
#
# Vay bang nay dung cho gi? Ba viec, deu la ngoai le that:
#
#   1. blackhole   chan mot dai dia chi o tang TGW, truoc ca firewall.
#                  Dung khi can cach ly nhanh mot mang - vi du mot
#                  spoke bi xam nhap, hoac mot dai IP doi tac.
#
#   2. doi tac     dai dia chi khong thuoc landing zone, den qua VPN
#                  hoac Direct Connect attachment.
#
#   3. sua duong   dua mot dai cu the di huong khac voi mac dinh, vi
#                  du mot spoke dung chung duong ra rieng.
#
# Ai them mot dong khong thuoc ba loai tren thi rat co the dang giai
# sai bai toan. lint.sh in canh bao cho truong hop do.
########################################

locals {
  ########################################
  # DICH DEN LAYER CHA DA SO HUU
  #
  # Khai lai mot trong so nay se bi AWS tu choi (route trung trong
  # cung mot bang), nhung loi hien ra la mot ma loi API o giua mot
  # apply - khong noi rang route do thuoc layer khac va khong nen dung
  # o day. Chan som voi mot cau noi ro hon.
  ########################################

  reserved_routes = merge(
    {
      "spokes/0.0.0.0/0"                      = "route mac dinh cua rtb-spokes, dua moi thu vao thanh tra"
      "egress/${local.hub.internal_supernet}" = "duong ve tu egress, quay lai security VPC"
    },
    local.hub.firewall.enabled ? {
      "security/0.0.0.0/0" = "duong ra Internet sau thanh tra"
    } : {},
    local.hub.firewall.enabled && contains(keys(local.hub.route_tables), "ingress") ? {
      "security/${local.hub.ingress_vpc_cidr}" = "duong ve NLB sau thanh tra"
      "ingress/${local.hub.internal_supernet}" = "tu NLB xuong app, qua security VPC"
    } : {},
    !local.hub.firewall.enabled && contains(keys(local.hub.route_tables), "ingress") ? {
      "spokes/${local.hub.ingress_vpc_cidr}" = "duong ve NLB khi tat firewall"
    } : {},
  )

  ########################################
  # GIAI TARGET
  #
  # Cu phap chuoi co tien to thay vi object long nhau. Ly do la DIFF:
  # "target: spoke:app-prod" -> "target: blackhole" la mot dong doi
  # trong PR, doc duoc trong ba giay. Object long nhau thi cung thay
  # doi do trai ra bon dong va nguoi duyet phai ghep lai trong dau.
  ########################################

  routes = {
    for r in local.routes_raw : try(r.id, "khong-co-id") => {
      id          = try(r.id, "")
      table       = try(r.table, "")
      destination = try(r.destination, "")
      target      = try(r.target, "")
      ticket      = try(r.ticket, "chua co")
      note        = try(r.note, "")

      table_id = try(local.hub.route_tables[r.table], null)

      blackhole = try(r.target, "") == "blackhole"

      # try() o MOI nhanh, ke ca nhanh khong duoc chon.
      #
      # Mot muc thieu han truong target thi r.target khong ton tai, va
      # loi hien ra la "This object does not have an attribute named
      # target" tro vao mot dong trong file .tf - khong noi la file
      # YAML nao, muc thu may. Doc chuoi rong o day de guard trong
      # main.tf duoc chay va noi cau tu te.
      attachment_id = (
        try(r.target, "") == "blackhole" ? null :
        startswith(try(r.target, ""), "spoke:") ? try(
          local.hub.spokes[trimprefix(try(r.target, ""), "spoke:")].attachment_id, null
        ) :
        startswith(try(r.target, ""), "hub:") ? try(
          local.hub.hub_attachments[trimprefix(try(r.target, ""), "hub:")], null
        ) :
        startswith(try(r.target, ""), "attachment:") ? trimprefix(try(r.target, ""), "attachment:") :
        null
      )
    }
  }

  ########################################
  # KIEM TRA
  ########################################

  rt_bad_table = [
    for k, v in local.routes : "${k} (${v.table})"
    if v.table_id == null
  ]

  rt_bad_target = [
    for k, v in local.routes : "${k} (${v.target})"
    if !v.blackhole && v.attachment_id == null
  ]

  rt_reserved = [
    for k, v in local.routes : "${k} -> ${v.table}/${v.destination}"
    if contains(keys(local.reserved_routes), "${v.table}/${v.destination}")
  ]

  # Route TINH tro toi mot dai NAM TRONG landing zone, dat trong bang
  # spokes. Day gan nhu luon la duong tat vong qua firewall.
  #
  # Khong chan - co truong hop dung that (blackhole de cach ly chinh
  # la kieu nay). Nhung phai noi to.
  rt_bypass_suspects = [
    for k, v in local.routes : k
    if v.table == "spokes" && !v.blackhole && can(cidrhost(v.destination, 0))
    && tonumber(split("/", v.destination)[1]) >= tonumber(split("/", local.hub.internal_supernet)[1])
    && cidrhost(
      "${split("/", v.destination)[0]}/${split("/", local.hub.internal_supernet)[1]}", 0
    ) == cidrhost(local.hub.internal_supernet, 0)
    && v.target != "hub:security"
  ]
}

resource "aws_ec2_transit_gateway_route" "ops" {
  for_each = local.routes

  transit_gateway_route_table_id = each.value.table_id
  destination_cidr_block         = each.value.destination

  # Dung mot trong hai, khong bao gio ca hai.
  blackhole                     = each.value.blackhole
  transit_gateway_attachment_id = each.value.blackhole ? null : each.value.attachment_id
}

########################################
# KIEM TRA CHEO
########################################

check "no_firewall_bypass_routes" {
  assert {
    condition = length(local.rt_bypass_suspects) == 0
    error_message = join("\n", [
      "Cac route sau dat trong bang 'spokes', tro toi mot dai NAM TRONG ${local.hub.internal_supernet}, va KHONG di qua security VPC:",
      "  ${join(", ", local.rt_bypass_suspects)}",
      "Route cu the hon 0.0.0.0/0 nen no THANG - luu luong toi dai do se bo qua firewall hoan toan.",
      "Neu day dung la y ban (vi du mot dai doi tac khong can thanh tra) thi ghi ro ly do vao truong note.",
    ])
  }
}

check "routes_have_an_owner" {
  assert {
    condition     = alltrue([for k, v in local.routes : v.ticket != "chua co"])
    error_message = "Co route khong khai ticket. Route ngoai le la thu kho doan nhat trong ca bo - khong co ticket thi khong ai dam go."
  }
}
