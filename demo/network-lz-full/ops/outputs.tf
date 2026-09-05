########################################
# OUTPUT
########################################

output "rule_group_arn" {
  description = <<-EOT
    ARN can dan sang layer cha MOT LAN, luc bootstrap. SUA dong
    ops_rule_group_arns trong ../terraform.tfvars roi:

      cd .. && terraform apply

    DUNG dung `echo >> terraform.tfvars`. Lan dung dau tien thi chay,
    nhung lan dung lai thu hai dong do da co san - va append cho ra
    HAI dong. Terraform tu choi:

      Error: Attribute redefined
      The argument "ops_rule_group_arns" was already set at ...

    No khong lay dong cuoi, khong canh bao rong: no dung han.

    Sau do khong dung toi nua: sua catalog chi doi rules_string ben
    trong, ARN giu nguyen.
  EOT
  value       = aws_networkfirewall_rule_group.ops_east_west.arn
}

output "bootstrap_done" {
  description = "Layer cha da tro toi rule group nay chua. false = moi rule trong catalog dang khong co tac dung."
  value = contains(
    local.hub.firewall.ops_rule_group_arns,
    aws_networkfirewall_rule_group.ops_east_west.arn,
  )
}

output "summary" {
  description = "Catalog dang co gi, dem tu chinh du lieu sap apply"
  value = {
    apps      = length(local.apps)
    rules     = length(local.fw_rules)
    routes    = length(local.routes)
    endpoints = length(local.endpoints)
    records   = length(local.dns_records)
    partners  = length(local.partners_raw)
    services  = length(local.partner_services)

    capacity = "${local.fw_capacity_used}/${var.rule_group_capacity}"

    firewall_mode = local.hub.firewall.mode
    expired       = local.fw_expired
    expiring_30d  = local.fw_expiring_soon

    # Dich vu doi tac het han la mot CUA MO ra ngoai con mo. Tach
    # rieng khoi rule firewall vi hai thu doi hai hanh dong khac
    # nhau: go rule la thu hep, go listener la dong cua.
    services_expired      = local.partner_service_expired
    services_expiring_30d = local.partner_service_soon
  }
}

output "rules" {
  description = <<-EOT
    Rule sau khi GIAI TEN. Doc bang nay truoc khi apply.

    Day la cho duy nhat thay duoc catalog thanh cai gi. YAML noi
    "order-api goi user-db"; bang nay noi "10.20.0.0/16 -> 10.21.0.0/16
    port 5432". Neu mot dong ra 0.0.0.0/32 thi ten do khong giai duoc
    va rule do se khong khop gi - nhung guard trong main.tf da dung
    plan truoc khi den day.
  EOT
  value = {
    for r in local.fw_rules : r.id => {
      from    = "${r.from} (${r.from_cidr})"
      to      = "${r.to} (${r.to_cidr})"
      ports   = r.protocol == "icmp" ? "icmp" : join(",", [for p in r.ports : tostring(p)])
      sid     = r.sid
      ticket  = r.ticket
      expires = r.expires == null ? "vinh vien" : tostring(r.expires)
    }
  }
}

output "rules_string" {
  description = "Chuoi Suricata that su duoc nap. So voi log alert khi mot rule khong hoat dong nhu mong doi."
  value       = join("\n", local.fw_rules_sorted)
}

output "endpoints_dns" {
  description = "Ten DNS cua endpoint do lop nay tao, va lenh kiem tu TRONG spoke"
  value = length(local.endpoints) == 0 ? [] : concat(
    ["Chay tu EC2 trong spoke (aws ssm start-session --target <id>):", ""],
    [for k, d in local.vpce_domain : "  dig +short ${d}"],
    [
      "",
      "Ket qua PHAI la IP trong ${local.hub.security_vpc_cidr}.",
      "Ra IP cong khai = PHZ chua toi duoc spoke do: endpoint van tinh",
      "tien, luu luong van di vong ra Internet qua NAT, va khong co gi bao.",
    ],
  )
}

output "next_steps" {
  description = "Viec con lai, tinh tu trang thai hien tai"
  value = compact([
    contains(local.hub.firewall.ops_rule_group_arns, aws_networkfirewall_rule_group.ops_east_west.arn)
    ? "" : "BOOTSTRAP: dan ARN vao ops_rule_group_arns cua layer cha roi apply mot lan. Xem output rule_group_arn.",

    local.hub.firewall.mode == "drop" || length(local.fw_rules) == 0
    ? "" : "Firewall dang o che do '${local.hub.firewall.mode}': rule duoc nap nhung mac dinh van cho qua. Chuyen sang 'drop' o layer cha khi da doc du log UNMATCHED east-west.",

    length(local.fw_expired) == 0
    ? "" : "Go rule qua han: ${join(", ", local.fw_expired)}",

    length(local.fw_expiring_soon) == 0
    ? "" : "Sap het han trong 30 ngay: ${join(", ", local.fw_expiring_soon)}",

    local.fw_capacity_used <= var.rule_group_capacity * 0.8
    ? "" : "Capacity da dung ${local.fw_capacity_used}/${var.rule_group_capacity} (>80%). Nang capacity la TAO LAI rule group va doi ARN - lam som, dung doi day.",
  ])
}

########################################
# DICH VU CONG BO CHO DOI TAC
#
# Bang nay la thu dua cho nguoi duyet, va la thu dua cho chinh doi
# tac. No noi bang dia chi va cong - khong bang ten - vi ten chi co
# nghia trong catalog nay, con doi tac thi cam mot dia chi va mot so.
########################################

output "partner_services" {
  description = "Doi tac nao goi duoc gi, o cong nao, toi dia chi nao"
  value = {
    for k, s in local.partner_services : k => {
      partner  = s.partner
      service  = s.service
      endpoint = "${try(local.hub.partner.nlb_dns, "?")}:${s.port}"
      target   = "${s.target} (${s.target_ip})"
      ticket   = s.ticket
      expires  = s.expires == null ? "khong han" : tostring(s.expires)
    }
  }
}

output "partner_handover" {
  description = "Van ban ky thuat dua cho doi tac - dan thang vao email"
  value = !try(local.hub.partner.enabled, false) ? "(chua bat ket noi doi tac o layer cha)" : join("\n", concat([
    "",
    "════════ THONG TIN KY THUAT CHO DOI TAC ════════",
    "",
    "1. DAI CHUNG TOI CONG BO CHO BAN",
    "   ${try(local.hub.partner.nat_cidr, "?")}   (dia chi nguon khi chung toi goi ra)",
    "   ${try(local.hub.partner.nlb_cidr, "?")}  (dia chi dich vu ban goi vao)",
    "",
    "   Dinh tuyen THEM bat cu dai nao khac qua duong ham nay se khong",
    "   di toi dau: khong co duong, va goi tin bi vut khong bao loi.",
    "",
    "2. DAI BAN CONG BO CHO CHUNG TOI",
    "   ${try(local.hub.partner.remote_cidr, "?")}",
    ], length(local.partner_extra_cidrs) == 0 ? [] : [
    "   ${join("\n   ", local.partner_extra_cidrs)}   (dai phu)",
    ], [
    "",
    "3. DICH VU BAN GOI DUOC",
    ], length(local.partner_services) == 0 ? [
    "   (chua cong bo dich vu nao)",
    ] : [
    for k, s in local.partner_services :
    "   ${s.partner}/${s.service}   ${try(local.hub.partner.nlb_dns, "?")}:${s.port}${s.expires == null ? "" : "   den ${s.expires}"}"
    ], [
    "",
    "4. DUONG HAM",
    "   IKEv2, PSK, static route (khong BGP).",
    "   Hai duong ham - AWS chi bao dam MOT UP tai mot thoi diem.",
    "   Thiet bi cua ban phai chap nhan ca hai va tu chuyen khi mot cai dut.",
    "",
    "5. DIEU KHONG THE THUONG LUONG",
    "   Ban khong goi duoc toi bat cu dia chi nao ngoai muc 1. Do khong",
    "   phai gioi han cau hinh - khong co duong nao ton tai.",
    "",
    "════════════════════════════════════════════════",
    "",
  ]))
}
