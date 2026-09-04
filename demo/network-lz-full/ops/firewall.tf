########################################
# RULE FIREWALL EAST-WEST SINH TU CATALOG
#
# Mo mot port giua hai app la thao tac hang ngay. Sau day la toan bo
# viec phai lam:
#
#   1. them mot khoi vao catalog/firewall-rules.yaml
#   2. ./lint.sh
#   3. mo PR, co nguoi duyet
#   4. terraform apply
#
# KHONG dong route nao. KHONG cham vao TGW. Route 0.0.0.0/0 trong
# rtb-spokes da phu moi cap spoke roi - xem ../tgw.tf. Cau tra loi cho
# "them route vpc-to-vpc" van la KHONG.
#
# Con phai lam ngoai Terraform: security group hai dau. Firewall cho
# goi tin di qua; security group cua instance dich van phai mo port.
# Hai lop, hai chu, va do la co y - khong lop nao mot minh mo duoc
# duong.
########################################

locals {
  ########################################
  # GIAI RULE
  ########################################

  fw_rules = [
    for r in local.fw_raw : {
      id       = try(r.id, "")
      from     = try(r.from, "")
      to       = try(r.to, "")
      protocol = lower(try(r.protocol, "tcp"))
      ports    = try(r.ports, [])
      ticket   = try(r.ticket, "chua co")
      note     = try(r.note, "")

      # NGAY HET HAN - hai bay chong len nhau.
      #
      # 1. yamldecode doi mot ngay KHONG DAT TRONG NHAY thanh dau thoi
      #    gian day du: `expires: 2027-12-31` doc ra
      #    "2027-12-31T00:00:00Z". Dat trong nhay thi van la chuoi 10
      #    ky tu. substr(...,0,10) cho ca hai ve cung mot dang.
      #
      # 2. HCL KHONG so sanh duoc chuoi bang > hay <. Toan tu do doi
      #    SO. So sanh hai chuoi ngay ISO trong thu tu tu dien la dung
      #    ve mat lich, nhung Terraform tu choi thang:
      #
      #      Error: Invalid operand
      #      Unsuitable value for left operand: a number is required.
      #
      # Nen doi thanh so YYYYMMDD - 20271231 - roi so bang so. Van
      # giu dung thu tu thoi gian, va la thu HCL chiu.
      expires = try(r.expires, null) == null ? null : substr(tostring(r.expires), 0, 10)

      expires_num = try(r.expires, null) == null ? null : tonumber(
        replace(substr(tostring(r.expires), 0, 10), "-", "")
      )

      from_cidr = try(local.apps[r.from].cidr, local.unresolvable)
      to_cidr   = try(local.apps[r.to].cidr, local.unresolvable)

      # sid tinh TU ID, khong tu vi tri. Xem var.sid_base.
      sid = var.sid_base + tonumber(try(regex("^fw-([0-9]{4})$", try(r.id, ""))[0], 0))
    }
  ]

  # Ngay hom nay theo dong ho cua Terraform luc PLAN.
  #
  # plantimestamp() chi ton tai trong plan, khong ghi vao state, nen
  # dung o day KHONG tao diff vinh vien. timestamp() thi co - va do la
  # ly do no khong duoc xuat hien o bat ky doi so resource nao trong
  # file nay.
  today     = substr(plantimestamp(), 0, 10)
  today_num = tonumber(replace(local.today, "-", ""))

  # Moc 30 ngay toi, cung dang so YYYYMMDD
  soon_num = tonumber(formatdate("YYYYMMDD", timeadd("${local.today}T00:00:00Z", "720h")))

  fw_expired = [
    for r in local.fw_rules : r.id
    if r.expires_num != null && local.today_num > r.expires_num
  ]

  # Rule sap het han trong 30 ngay - dua vao output de doi lich.
  fw_expiring_soon = [
    for r in local.fw_rules : "${r.id} (${r.expires})"
    if r.expires_num != null
    && r.expires_num >= local.today_num
    && r.expires_num <= local.soon_num
  ]

  ########################################
  # KIEM TRA - guard trong main.tf doc cac bang nay
  ########################################

  fw_bad_id = [
    for r in local.fw_raw : tostring(try(r.id, "(thieu id)"))
    if !can(regex("^fw-(?:[0-8][0-9]{3})$", try(r.id, ""))) || try(r.id, "") == "fw-0000"
  ]

  fw_unknown_app = distinct(flatten([
    for r in local.fw_raw : [
      for who in [try(r.from, ""), try(r.to, "")] :
      "${try(r.id, "?")}:${who}" if !contains(local.app_names, who)
    ]
  ]))

  fw_bad_port = [
    for r in local.fw_rules : r.id
    if(
      # icmp thi khong duoc khai port
      (r.protocol == "icmp" && length(r.ports) > 0)
      # tcp/udp thi phai co it nhat mot port hop le
      || (r.protocol != "icmp" && (
        length(r.ports) == 0
        || !alltrue([for p in r.ports : can(tonumber(p)) && tonumber(p) >= 1 && tonumber(p) <= 65535])
      ))
      || !contains(["tcp", "udp", "icmp"], r.protocol)
    )
  ]

  # from va to giai ra cung mot CIDR.
  #
  # Luong trong CUNG mot VPC khong di qua TGW - no di thang trong
  # local route cua VPC. Nen rule nay khong bao gio khop, va khong co
  # gi bao. Nguoi mo ticket se doi mai mot thay doi da apply xong.
  fw_self = [
    for r in local.fw_rules : r.id
    if r.from_cidr == r.to_cidr && r.from_cidr != local.unresolvable
  ]

  ########################################
  # SINH CHUOI SURICATA
  #
  # Dang: pass <proto> <src> any -> <dst> <ports> (msg:"..."; sid:N; rev:1;)
  #
  # Danh sach port dung cu phap [80,443] cua Suricata - mot rule cho
  # nhieu port, thay vi mot rule moi port. It dong hon thi it capacity
  # hon, va sid van la mot cho mot dong YAML.
  #
  # msg la thu HIEN RA TRONG LOG ALERT. Nhet ca id va ticket vao day
  # co ly do: khi doc log luc 2 gio sang, "ops fw-0007 NET-1234" tra
  # nguoc ve dung mot dong trong git va dung mot ticket. "ALLOW app to
  # db" thi khong.
  ########################################

  fw_rule_strings = [
    for r in local.fw_rules :
    r.protocol == "icmp" ? format(
      "pass icmp %s any -> %s any (msg:\"ops %s %s\"; sid:%d; rev:1;)",
      r.from_cidr, r.to_cidr, r.id, r.ticket, r.sid,
      ) : format(
      "pass %s %s any -> %s %s (msg:\"ops %s %s\"; sid:%d; rev:1;)",
      r.protocol,
      r.from_cidr,
      r.to_cidr,
      length(r.ports) == 1 ? tostring(r.ports[0]) : "[${join(",", [for p in r.ports : tostring(p)])}]",
      r.id, r.ticket, r.sid,
    )
  ]

  # SAP XEP theo sid.
  #
  # Khong phai cho dep. rules_string la MOT chuoi: doi thu tu cac dong
  # la doi chuoi, va Terraform bao "rule group se duoc cap nhat" cho
  # mot thay doi khong co noi dung. O STRICT_ORDER thi thu tu con doi
  # ca y nghia danh gia. Sap theo sid cho ket qua on dinh bat ke ai
  # them dong o dau trong file YAML. Cung ho voi loi 39.
  fw_rules_sorted = sort(local.fw_rule_strings)

  # Uoc tinh capacity da dung.
  #
  # Network Firewall tinh capacity cua rule Suricata theo so to hop
  # (so CIDR nguon x so CIDR dich x so port). Rule cua ta luon 1 nguon
  # x 1 dich, nen chi phi la so port. Cong 10% du phong.
  fw_capacity_used = ceil(sum(concat([0], [
    for r in local.fw_rules : max(1, length(r.ports))
  ])) * 1.1)
}

########################################
# RULE GROUP
#
# Resource DUY NHAT ma layer cha phai biet den. ARN cua no di vao
# var.ops_rule_group_arns ben kia, MOT LAN.
#
# Tu do moi thay doi trong catalog chi lam doi rules_string - mot
# thuoc tinh sua tai cho, khong tao lai resource, khong doi ARN, va
# khong can ai apply layer cha.
########################################

resource "aws_networkfirewall_rule_group" "ops_east_west" {
  name = "${local.hub.project}-ops-east-west"
  type = "STATEFUL"

  # BAT BIEN - xem var.rule_group_capacity
  capacity = var.rule_group_capacity

  description = "Rule east-west sinh tu ops/catalog/firewall-rules.yaml"

  rule_group {
    # PHAI KHOP RULE ORDER CUA POLICY - loi 47.
    #
    # Policy ben ../firewall.tf dat STRICT_ORDER. Rule group khong khai
    # thi mac dinh la DEFAULT_ACTION_ORDER, va CreateFirewallPolicy tu
    # choi voi mot cau noi ve "ResourceArn has invalid rule order" chu
    # khong noi thieu dong nao. Va no tu choi ben LAYER CHA, tuc la
    # loi hien ra o mot layer khong ai vua sua gi.
    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }

    rules_source {
      # Catalog rong -> mot rule khong lam gi.
      #
      # rules_string RONG bi API tu choi, nen phai co it nhat mot dong.
      # Dung "alert" chu khong phai "pass": mot rule group vua bootstrap
      # xong khong duoc quyen mo them duong nao.
      rules_string = length(local.fw_rules_sorted) > 0 ? join("\n", local.fw_rules_sorted) : join("\n", [
        "alert ip ${local.hub.internal_supernet} any -> ${local.hub.internal_supernet} any (msg:\"ops catalog rong\"; sid:${var.sid_base}; rev:1;)",
      ])
    }
  }

  tags = {
    Name = "${local.hub.project}-ops-east-west"
    # So rule dang chay, doc duoc tu console ma khong can mo Terraform
    Rules = tostring(length(local.fw_rules))
  }

  lifecycle {
    precondition {
      condition     = local.fw_capacity_used <= var.rule_group_capacity
      error_message = "Catalog can ~${local.fw_capacity_used} capacity nhung rule group chi co ${var.rule_group_capacity}. Nang capacity la XOA VA TAO LAI rule group, va ARN moi khong khop var.ops_rule_group_arns ben layer cha - xem chu thich cua bien do truoc khi doi."
    }
  }
}

########################################
# KIEM TRA CHEO - canh bao, khong chan
########################################

# Rule group ton tai ma khong duoc cam vao policy.
#
# Trang thai nay doc nhu thanh cong tu moi phia: apply xanh, rule group
# hien trong console, rules_string dung y nguyen catalog. Chi co mot
# thu thieu - khong policy nao doc no. Moi rule trong catalog khong
# lam gi ca, va khong co cho nao bao dieu do.
check "rule_group_is_referenced" {
  assert {
    condition = contains(
      local.hub.firewall.ops_rule_group_arns,
      aws_networkfirewall_rule_group.ops_east_west.arn,
    )
    error_message = join("\n", [
      "Rule group nay CHUA duoc firewall policy tham chieu - moi rule trong catalog dang khong co tac dung.",
      "Them ARN sau vao ops_rule_group_arns trong terraform.tfvars cua layer cha roi apply mot lan:",
      "  ${aws_networkfirewall_rule_group.ops_east_west.arn}",
    ])
  }
}

# Firewall dang o che do alert: rule pass van duoc nap, nhung mac dinh
# cung la cho qua, nen "mo port" khong chung minh duoc gi.
check "firewall_mode_makes_rules_meaningful" {
  assert {
    condition     = local.hub.firewall.mode == "drop" || length(local.fw_rules) == 0
    error_message = "Firewall dang o che do '${local.hub.firewall.mode}': mac dinh la cho qua va CHI GHI LOG. ${length(local.fw_rules)} rule trong catalog van duoc nap nhung khong quyet dinh gi - luong khong co rule cung di qua binh thuong. Day la trang thai dung khi dang do duong; nho rang no cung nghia la ban chua kiem chung duoc rule nao that su can thiet."
  }
}

check "no_expired_rules" {
  assert {
    condition     = length(local.fw_expired) == 0
    error_message = "Rule qua han van dang chay: ${join(", ", local.fw_expired)}. Chung KHONG tu bien mat - xem var.allow_expired_rules."
  }
}

# Rule icmp o lop nay khong bao gio duoc doc toi.
#
# ../firewall.tf co san "pass icmp <supernet> any -> <supernet> any"
# (sid 1900) trong rule group uu tien 100. Rule group cua lop nay o
# 150. O STRICT_ORDER, pass la hanh dong KET THUC danh gia - nen moi
# luong icmp noi bo da duoc quyet dinh xong truoc khi toi day.
#
# Rule van apply thanh cong, van hien trong console, van chiem
# capacity. Do la toan bo van de: khong co gi trong he thong noi rang
# no vo tac dung.
check "icmp_rules_are_shadowed" {
  assert {
    condition     = length([for r in local.fw_rules : r.id if r.protocol == "icmp"]) == 0
    error_message = "Rule icmp o lop nay khong bao gio duoc doc toi: ${join(", ", [for r in local.fw_rules : r.id if r.protocol == "icmp"])}. Layer cha da cho qua MOI luong icmp noi bo o rule group uu tien 100 (sid 1900), va o STRICT_ORDER thi pass ket thuc danh gia. Go chung di cho do ton capacity, hoac neu ban muon CHAN icmp thi phai sua sid 1900 ben layer cha - khong chan duoc tu day."
  }
}

check "rules_have_an_owner" {
  assert {
    condition     = alltrue([for r in local.fw_rules : r.ticket != "chua co"])
    error_message = "Co rule khong khai ticket. Mot nam nua se khong ai biet vi sao no o do, va khong ai dam go - dai rule chi dai them chu khong ngan lai bao gio."
  }
}
