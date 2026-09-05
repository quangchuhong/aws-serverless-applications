output "mode" {
  value = join(" | ", compact([
    var.enable_firewall ? "Network Firewall (${var.firewall_mode})" : "khong firewall",
    var.enable_cdn ? "CloudFront + WAF (${var.waf_mode})" : "",
    var.enable_appliances ? "Palo Alto + F5" : "",
  ]))
}

output "nat_public_ips" {
  description = <<-EOT
    AZ -> IP cong khai cua NAT. Moi AZ mot cai.

    Day la TOAN BO dia chi ma landing zone dung khi goi ra Internet.
    EC2 trong spoke curl checkip.amazonaws.com PHAI ra mot trong so
    nay - ra IP khac nghia la co duong ra khong qua egress VPC.

    Dua ca danh sach cho doi tac de allowlist, va kiem lai khi them AZ.
  EOT
  value       = { for z, e in aws_eip.nat : z => e.public_ip }
}

output "transit_gateway_id" {
  value = aws_ec2_transit_gateway.hub.id
}

# verify.sh va teardown.sh DOI CHIEU OUTPUT NAY voi credential dang
# dung. Xoa no = hai script mat cai chan chong chay nham account.
output "account_id" {
  description = "Account da tao ha tang nay. Chay script bang credential cua account KHAC se do nham thu khac."
  value       = data.aws_caller_identity.current.account_id
}

output "security_vpc_id" {
  value = one(aws_vpc.security[*].id)
}

output "firewall_endpoints" {
  description = "AZ -> firewall endpoint ID. Route cua moi AZ phai tro vao dung endpoint cua AZ do."
  value       = local.fw_endpoints
}

output "nlb_dns_name" {
  value = one(aws_lb.ingress[*].dns_name)
}

output "cloudfront_domain" {
  description = "Hostname mac dinh cua CloudFront - khong can mua domain"
  value       = one(aws_cloudfront_distribution.main[*].domain_name)
}

output "waf_web_acl_arn" {
  value = one(aws_wafv2_web_acl.cdn[*].arn)
}

output "appliances" {
  description = "Palo Alto va F5 - null khi enable_appliances = false"
  value = {
    palo_alto_id    = one(aws_instance.palo_alto[*].id)
    f5_id           = one(aws_instance.f5[*].id)
    f5_private_ip   = one(aws_instance.f5[*].private_ip)
    gwlb_endpoint   = one(aws_vpc_endpoint.gwlbe[*].id)
    f5_config_s3    = one(aws_s3_bucket.f5_config[*].id)
    f5_admin_secret = one(aws_secretsmanager_secret.f5_admin[*].name)
  }
}

output "firewall_log_bucket" {
  value = one(aws_s3_bucket.fw_logs[*].id)
}

output "instances" {
  value = {
    for k, v in aws_instance.test : k => {
      id         = v.id
      private_ip = v.private_ip
      vpc_cidr   = local.local_spokes[k].cidr
    }
  }
}

########################################
# Uoc tinh chi phi
########################################

locals {
  c_tgw_attach = 0.05
  c_nat        = 0.045
  c_fw         = 0.395
  c_nlb        = 0.0225
  c_vpce       = 0.01
  c_ec2        = 0.0116

  # WAF: Web ACL ~$5/thang + ~$1/thang moi rule group, chia theo gio.
  # CloudFront: $0 trong free tier (1 TB + 10 trieu request/thang).
  c_waf_acl  = 5.0 / 730
  c_waf_rule = 1.0 / 730

  # Appliance: EC2 + license Marketplace tinh theo gio.
  # Gia license dao dong RAT LON theo bundle - day chi la uoc tinh tho,
  # kiem tra gia that tren trang Marketplace cho dung bundle ban dung.
  # VPN connection tinh theo gio ke ca khi duong ham DOWN - AWS tinh
  # tu luc tao, khong tu luc len.
  c_vpn = 0.05

  c_gwlb      = 0.0125
  c_gwlbe     = 0.01
  c_palo_alto = 1.50 # EC2 m5.xlarge (~$0.24) + license (~$1.3)
  c_f5        = 1.50 # EC2 m5.xlarge (~$0.24) + license (~$1.3)

  # MOT attachment moi VPC, khong phu thuoc so AZ - them AZ chi them
  # subnet vao attachment da co.
  # Dem CA spoke noi bo lan remote: moi attachment deu tinh tien nhu nhau.
  n_attach = length(var.spokes) + 1 + local.fw + local.ing + local.ptn

  # Nhung thu NHAN LEN theo so AZ. Bo qua he so nay la bao gia bang
  # mot nua su that khi chay 2 AZ.
  n_az = length(var.availability_zones)

  hourly = (
    local.n_attach * local.c_tgw_attach

    # NAT Gateway: mot moi AZ
    + local.n_az * local.c_nat

    # Firewall endpoint: mot moi AZ - khoan nhan len dat nhat
    + (var.enable_firewall ? local.n_az * local.c_fw : 0)

    # NLB tinh theo AZ duoc bat
    + (var.enable_ingress ? local.n_az * local.c_nlb : 0)

    # Interface endpoint: mot ENI moi AZ moi dich vu
    + (var.enable_firewall && var.enable_interface_endpoints
      ? local.n_az * length(var.interface_endpoint_services) * local.c_vpce
    : 0)

    # EC2 test: mot con moi spoke, KHONG theo AZ
    + (var.enable_test_instances ? length(local.local_spokes) * local.c_ec2 : 0)

    + (local.cdn > 0 ? local.c_waf_acl + (length(var.waf_managed_rule_groups) + 1) * local.c_waf_rule : 0)

    # Appliance don chiec, dat o AZ dau - khong nhan len
    + (local.app_on > 0 ? local.c_gwlb + local.c_gwlbe + local.c_palo_alto + local.c_f5 : 0)

    # Doi tac: VPN + private NAT + EC2 don chiec, NLB theo AZ.
    # Attachment cua 3rd-party VPC da tinh trong n_attach.
    + (local.ptn > 0
      ? local.c_vpn + local.c_nat + local.c_ec2 + local.n_az * local.c_nlb
    : 0)
  )
}

output "tgw_shared_with" {
  description = <<-EOT
    Account duoc thay Transit Gateway, va lenh moi account phai chay
    MOT LAN de nhan loi moi. Share ngoai to chuc khong tu dong duoc
    chap nhan.
  EOT
  # KHONG dung `dieu_kien ? {} : {...}`: hai nhanh cua toan tu ba ngoi
  # phai CUNG KIEU, va mot object rong khong cung kieu voi object ba
  # thuoc tinh. Luon tra ve du ba thuoc tinh; accounts tu rong khi
  # khong share cho ai.
  value = {
    accounts = sort(local.ram_principals)
    # LOC THEO TEN SHARE.
    #
    # Ban dau lenh nay nhan MOI loi moi dang cho trong account. Tien,
    # nhung no bien mot buoc co chu dich thanh mot cai bam mu: account
    # do co the dang cho loi moi tu noi khac, va lenh se nhan luon.
    accept = join(" ", [
      "ARN=$(aws ram get-resource-share-invitations --region", var.region,
      "--query \"resourceShareInvitations[?status=='PENDING' && resourceShareName=='${var.project}-tgw'].resourceShareInvitationArn\"",
      "--output text); [ -n \"$ARN\" ] && aws ram accept-resource-share-invitation",
      "--region", var.region, "--resource-share-invitation-arn \"$ARN\"",
    ])

    # Bang chung THAT, chay tu chinh account vua nhan. Trang thai
    # ACCEPTED phia RAM chi noi loi moi da duoc nhan, khong noi TGW da
    # hien ra ben do.
    verify = "aws ec2 describe-transit-gateways --region ${var.region} --query 'TransitGateways[].[TransitGatewayId,OwnerId]' --output text"
  }
}

output "spoke_names" {
  description = <<-EOT
    Ten cac spoke NOI BO trong account nay. verify.sh dung de tim VPC
    va route table cua chung.

    Truoc day script loc theo tag "<project>-app-*-vpc" - mot quy uoc
    dat ten, khong phai su that. Doi ten spoke tu "app-dev" thanh
    "probe" la hai phep kiem dau tien KHONG IN GI CA: vong lap khong
    khop, than vong lap khong chay, va bang ket qua ngan di hai dong
    ma khong bao gi. Loi 62.
  EOT
  value       = sort(keys(local.local_spokes))
}

output "test_targets" {
  description = <<-EOT
    Moi spoke -> IP cua EC2 kiem chung trong do, ke ca spoke o account
    khac. verify.sh dung bang nay de goi tu spoke nay sang spoke kia.

    IP cua spoke REMOTE la tinh truoc, khong phai doc tu AWS: Terraform
    khong doc duoc output cua stack instance, va script khong co
    credential o account do. Xem local.remote_test_ips.

    Nghia la neu template doi cach chia subnet ma cong thuc khong doi
    theo, bang nay se tro vao dia chi khong co ai o do - va phep kiem
    se bao "khong thong" cho mot mang hoan toan binh thuong.
  EOT
  value = merge(
    { for k, v in aws_instance.test : k => { ip = v.private_ip, account = "local", how = "doc tu AWS" } },
    { for k, ip in local.remote_test_ips : k => {
      ip      = ip
      account = local.stackset_spokes[k].account_id
      how     = "tinh truoc"
    } },
  )
}

output "spoke_template" {
  description = <<-EOT
    Template CloudFormation cua spoke VPC, de dung BANG TAY o account
    ma StackSet khong voi toi - management account, loi 59.

      terraform output -raw spoke_template > spoke-vpc.json

    Roi tu chinh account do:

      aws cloudformation create-stack --region <region> \
        --stack-name <project>-spoke-vpc \
        --template-body file://spoke-vpc.json \
        --parameters \
          ParameterKey=VpcCidr,ParameterValue=10.101.0.0/16 \
          ParameterKey=TransitGatewayId,ParameterValue=<tgw-id> \
          ParameterKey=AzA,ParameterValue=<region>a \
          ParameterKey=AzB,ParameterValue=<region>b \
          ParameterKey=ProjectName,ParameterValue=<project> \
          ParameterKey=SpokeName,ParameterValue=management \
          ParameterKey=DnsProfileId,ParameterValue=<profile-id>

    Doc thang tu stack set dang chay, KHONG phai mot ban sao: hai ban
    template roi nhau ra la kieu loi khong ai phat hien cho toi khi
    mot spoke duoc dung khac moi spoke con lai.

    Sau khi stack chay xong, `terraform apply` se tu noi attachment do
    vao route table - viec do la cua chu so huu TGW, khong lien quan
    toi cach VPC duoc tao.
  EOT
  value       = try(aws_cloudformation_stack_set.spoke[0].template_body, "")
}

output "estimated_cost" {
  description = <<-EOT
    Uoc tinh THO phi co dinh. Chua tinh data transfer.

    Da nhan theo so AZ cho: NAT, firewall endpoint, NLB, interface
    endpoint. TGW attachment thi KHONG - mot attachment moi VPC du co
    bao nhieu AZ.
  EOT
  value       = format("~$%.3f/gio  |  ~$%.2f/ngay  |  ~$%.0f/thang", local.hourly, local.hourly * 24, local.hourly * 730)
}

output "next_steps" {
  value = <<-EOT

    ══════════════════ KIEM CHUNG ══════════════════

    1. Vao EC2 o ${coalesce(local.first_spoke, "<khong co spoke local>")} (vao duoc = duong egress OK):
       aws ssm start-session --target ${try(aws_instance.test[local.first_spoke].id, "<khong co EC2 local>")} --region ${var.region}
    ${local.first_spoke != null ? "" : trimspace(<<-NOTE

       KHONG CO SPOKE LOCAL nen khong vao duoc tu day: SSM cua account
       nay khong voi toi instance o account khac. Phai dung credential
       cua chinh account spoke. Va verify.sh muc 7 + 7c se bo qua, vi
       chung dieu khien phep do TU MOT EC2 local.
    NOTE
)}

    2. Trong session - IP ra Internet phai la NAT:
       curl -s https://checkip.amazonaws.com
       => phai la MOT trong: ${join(", ", [for e in aws_eip.nat : e.public_ip])}
          (moi AZ mot NAT, IP nao la tuy AZ cua EC2)

    3. Chay kiem chung tu dong:
       ./verify.sh

    4. Ingress:
    ${local.cdn > 0 ?
"   curl https://${aws_cloudfront_distribution.main[0].domain_name}\n       (goi thang vao NLB se bi CHAN - origin da khoa theo CloudFront)" :
"   curl http://${try(aws_lb.ingress[0].dns_name, "<bat enable_ingress>")}"}

    5. XOA khi xong:
       ./teardown.sh${local.cdn > 0 ? "   ← CloudFront lam destroy cham ~15-20 phut" : ""}

    ════════════════════════════════════════════════
    Chi phi hien tai: ${format("~$%.3f/gio", local.hourly)}
    ════════════════════════════════════════════════
  EOT
}

########################################
# teardown.sh DOC OUTPUT NAY
#
# Doc tu state chu khong tu tfvars: tfvars co the da bi sua sau lan
# apply cuoi, state thi phan anh cai dang chay that.
#
# Xoa output nay = cai chan trong teardown.sh im lang mat tac dung.
########################################

output "ephemeral" {
  description = "true = demo dung-xem-xoa. false = ha tang thuong tru, teardown.sh se tu choi chay."
  value       = var.ephemeral
}

########################################
# DNS TAP TRUNG
########################################

output "dns" {
  description = "PHZ noi bo, ban ghi sinh ra, va trang thai Route 53 Profile"
  value = {
    internal_zone    = try(aws_route53_zone.internal[0].name, null)
    internal_zone_id = try(aws_route53_zone.internal[0].zone_id, null)

    # Ten goi duoc tu trong spoke. Day la thu de thu that.
    records = { for k, r in aws_route53_record.spoke_app : k => r.name }

    # PHZ cua VPC endpoint - dich vu -> zone id
    endpoint_zones = { for k, z in aws_route53_zone.endpoint : k => z.zone_id }

    profile_enabled = var.enable_dns_profile
    profile_id      = try(aws_route53profiles_profile.shared[0].id, null)
    profile_shared  = var.enable_dns_profile && local.ram_share == 1
  }
}

output "dns_check" {
  description = "Lenh kiem DNS that su hoat dong - chay TRONG spoke qua SSM"

  # Dung join() chu KHONG dung %{for} trong heredoc: template directive
  # co thut le rieng, va <<-EOT strip theo dong it thut nhat - ket qua
  # la khoi lenh so le, dan vao terminal nhin rat kho.
  value = join("\n", concat(
    [
      "",
      "Chay tu EC2 trong spoke (aws ssm start-session --target <id>):",
      "",
      "  # 1. PHZ noi bo: goi spoke khac bang TEN, khong phai IP",
    ],

    length(aws_route53_record.spoke_app) > 0 ? flatten([
      for k, r in aws_route53_record.spoke_app : [
        "  dig +short ${r.name}",
        "  curl -s http://${r.name} | head -1",
      ]
    ]) : ["  (enable_internal_dns hoac enable_test_instances dang tat)"],

    [
      "",
      "  # 2. VPC endpoint tap trung: ten AWS phai tro vao IP NOI BO",
    ],

    [for k, z in aws_route53_zone.endpoint : "  dig +short ${k}.${var.region}.amazonaws.com"],

    [
      "",
      "  Ket qua PHAI la IP trong ${var.security_vpc_cidr} - do la interface",
      "  endpoint dat o security VPC. Ra IP cong khai nghia la PHZ chua toi",
      "  duoc spoke, va luu luong dang di vong ra Internet: endpoint van",
      "  tinh tien ma khong ai dung.",
      "",
      "  # 3. Gateway endpoint S3: KHONG qua TGW, khong ton tien",
      "  dig +short s3.${var.region}.amazonaws.com",
      "",
      "  Cai nay RA IP CONG KHAI - va do la DUNG. Gateway endpoint lam viec",
      "  o tang route table (prefix list), khong phai tang DNS.",
      "",
    ],
  ))
}

# Ten project - de verify.sh va teardown.sh tim resource theo tag Name
# ma KHONG phai doan. Truoc khi co output nay, verify.sh gan cung
# "lz-net"; ai doi var.project thi moi lookup theo tag deu tra ve None
# va script bao "THIEU duong ve", "rtb-spokes khong ton tai" - nghe
# nhu ha tang hong, thuc ra la tim sai ten. Xem loi 48 doc 22.
output "project" {
  description = "Tien to ten dung cho moi resource"
  value       = var.project
}

########################################
# HANDLE CHO LOP VAN HANH (ops/)
#
# Mot output duy nhat thay vi muoi hai cai roi rac. Ly do khong phai
# gon mat: ops/ doc bo nay qua terraform_remote_state, va MOI LAN them
# mot output la mot lan hai file phai sua khop nhau. Gom lai thi hop
# dong giua hai layer la MOT ten - de thay khi no doi, va `terraform
# output ops_handles` in ra dung nhung gi lop kia nhin thay.
#
# Moi truong nay dung state LOCAL. Voi landing-zone/network (backend
# S3) thi ops/ chi doi state_backend/state_config, khong doi gi khac.
########################################

output "ops_handles" {
  description = "Moi thu thu muc ops/ can. Doc qua terraform_remote_state, dung tra tay."

  value = {
    project           = var.project
    region            = var.region
    account_id        = data.aws_caller_identity.current.account_id
    internal_supernet = var.internal_supernet
    security_vpc_cidr = var.security_vpc_cidr
    ingress_vpc_cidr  = var.ingress_vpc_cidr

    firewall = {
      enabled = var.enable_firewall
      mode    = var.firewall_mode
      arn     = try(aws_networkfirewall_firewall.main[0].arn, null)

      # ops/ doi chieu danh sach nay voi rule group cua chinh no. Lech
      # nghia la ai do apply ops/ ma quen cam ARN vao layer nay - rule
      # ton tai, tinh phi, va khong duoc doc. Xem check trong ops/.
      ops_rule_group_arns = var.ops_rule_group_arns
    }

    transit_gateway_id = aws_ec2_transit_gateway.hub.id

    # Ten bang -> id. ops/ khai route theo TEN ("spokes"), khong phai
    # tgw-rtb-0abc: id doi moi lan dung lai, ten thi khong.
    route_tables = merge(
      {
        spokes = aws_ec2_transit_gateway_route_table.spokes.id
        egress = aws_ec2_transit_gateway_route_table.egress.id
      },
      var.enable_firewall ? { security = aws_ec2_transit_gateway_route_table.security[0].id } : {},
      var.enable_ingress ? { ingress = aws_ec2_transit_gateway_route_table.ingress[0].id } : {},
    )

    # Bang tra cuu TEN SPOKE -> CIDR + attachment.
    #
    # Day la thu lam cho catalog cua ops/ khai duoc bang ten thay vi
    # CIDR. Go nham mot chu so trong CIDR thi rule khong khop cai gi
    # ca va KHONG CO LOI O DAU HET - firewall im lang la trang thai
    # binh thuong cua no. Go nham mot cai ten thi Terraform dung ngay.
    spokes = {
      for k, v in var.spokes : k => {
        cidr       = v.cidr
        account_id = try(v.account_id, null)
        is_local   = try(v.account_id, null) == null

        # Chi spoke LOCAL moi co vpc_id. VPC cua spoke remote nam
        # trong account khac va Terraform nay khong doc duoc no - do
        # cung la ly do PHZ phai di qua Route 53 Profile chu khong gan
        # thang duoc. Xem ../dns.tf.
        vpc_id = try(aws_vpc.spoke[k].id, null)

        # Attachment id:
        #   spoke local  - doc thang tu resource
        #   spoke remote - chi giai duoc khi account do co DUNG MOT
        #                  attachment. Nhieu hon mot thi khong doan,
        #                  tra null va de nguoi van hanh khai tay.
        attachment_id = try(
          aws_ec2_transit_gateway_vpc_attachment.spoke[k].id,
          one([
            for att_id in try(data.aws_ec2_transit_gateway_attachments.remote_by_account[v.account_id].ids, []) : att_id
          ]),
          null,
        )
      }
    }

    # Attachment cua ha tang - dich hop le cho route tinh trong ops/
    hub_attachments = merge(
      { egress = aws_ec2_transit_gateway_vpc_attachment.egress.id },
      var.enable_firewall ? { security = aws_ec2_transit_gateway_vpc_attachment.security[0].id } : {},
      var.enable_ingress ? { ingress = aws_ec2_transit_gateway_vpc_attachment.ingress[0].id } : {},
    )

    # DOI TAC - lop ops giai ten "partner-*" tu day.
    #
    # Chi hai dai duoc cong bo, dung hai dai doi tac biet. KHONG dua
    # partner_sim_cidr vao cho de lop ops mo rule tro thang toi dai
    # cua doi tac: chieu do phai qua private NAT, va rule tro thang se
    # khong khop gi vi nguon da bi doi dia chi.
    partner = {
      enabled     = var.enable_partner_vpn
      vpc_cidr    = var.enable_partner_vpn ? var.partner_vpc_cidr : null
      nat_cidr    = var.enable_partner_vpn ? local.partner_nat_cidr : null
      nlb_cidr    = var.enable_partner_vpn ? local.partner_nlb_cidr : null
      remote_cidr = var.enable_partner_vpn ? var.partner_sim_cidr : null
      nlb_dns     = try(aws_lb.partner[0].dns_name, null)

      # Cong layer cha DA CHIEM.
      #
      # Mot NLB chi cho MOT listener tren mot cong. Lop ops mo them
      # listener cho dich vu moi, va neu no cham vao cong nay thi AWS
      # tu choi o GIUA apply - mot ma loi API khong noi rang cong do
      # thuoc layer khac.
      #
      # Doi ten thanh "reserved" de cho nao doc cung thay ngay day la
      # dieu cam, khong phai mot gia tri de dung lai.
      reserved_port = var.partner_service_port

      # BA HANDLE cho lop ops.
      #
      # Thieu chung thi lop ops khong the tu tao target group hay
      # listener, va viec cong bo mot dich vu moi cho doi tac lai phai
      # sua layer cha - tuc la mot thay doi hang tuan phai di qua mot
      # plan 200 resource.
      nlb_arn           = try(aws_lb.partner[0].arn, null)
      vpc_id            = try(aws_vpc.partner[0].id, null)
      vpn_connection_id = try(aws_vpn_connection.partner[0].id, null)

      # Security group cua NLB. Mo listener thoi CHUA DU: NLB loc luu
      # luong toi tung listener, nen thieu rule o day thi goi tin bi
      # vut truoc khi toi listener - het gio, khong log, khong loi.
      nlb_security_group_id = try(aws_security_group.partner_nlb[0].id, null)
    }

    dns = {
      enabled   = var.enable_internal_dns
      zone_id   = try(aws_route53_zone.internal[0].zone_id, null)
      zone_name = try(aws_route53_zone.internal[0].name, null)

      # Ban ghi do CHINH layer nay sinh ra. ops/ phai tranh trung ten
      # voi chung: hai aws_route53_record cung ten trong hai state
      # khac nhau thi cai apply sau ghi de cai truoc, va khong ben nao
      # bao gi - tham chi `terraform plan` cua ca hai deu sach.
      managed_records = [for k, r in aws_route53_record.spoke_app : r.name]

      profile_enabled = var.enable_dns_profile
      profile_id      = try(aws_route53profiles_profile.shared[0].id, null)
    }

    endpoints = {
      enabled            = var.enable_interface_endpoints
      vpc_id             = try(aws_vpc.security[0].id, null)
      subnet_ids         = [for z in var.availability_zones : try(aws_subnet.security_endpoints[z].id, null)]
      security_group_id  = try(aws_security_group.endpoints[0].id, null)
      route_table_id     = try(aws_route_table.security_endpoints[0].id, null)
      availability_zones = var.availability_zones

      # Dich vu layer nay da tao. ops/ them dich vu MOI va phai khong
      # dam vao danh sach nay - hai aws_vpc_endpoint cung service_name
      # trong cung VPC la hai ENI, hai hoa don, va PHZ thu hai che mat
      # PHZ thu nhat.
      managed_services = var.enable_interface_endpoints ? sort(var.interface_endpoint_services) : []
    }
  }
}

########################################
# DOI TAC
########################################

output "partner" {
  description = <<-EOT
    3rd-party VPC + VPN. null khi enable_partner_vpn = false.

    "advertised" la thu DUY NHAT doi tac duoc biet. Dua dung hai dai
    do vao hop dong ky thuat - khong bao gio dua 10.0.0.0/8.
  EOT

  value = !var.enable_partner_vpn ? null : {
    vpn_connection_id = aws_vpn_connection.partner[0].id
    customer_gateway  = aws_eip.partner_sim[0].public_ip
    sim_instance_id   = aws_instance.partner_sim[0].id

    # Dia chi doi tac goi toi, va spoke that dang tra loi phia sau no
    service_endpoint = "${aws_lb.partner[0].dns_name}:${var.partner_service_port}"
    real_target      = local.partner_target_ip

    advertised = local.partner_advertised
    remote     = var.partner_sim_cidr

    # Doc tu AWS chu khong tu state - tunnel len hay khong la chuyen
    # cua thoi diem, state khong biet.
    tunnel_status = join(" ", [
      "aws ec2 describe-vpn-connections --region ${var.region}",
      "--vpn-connection-ids ${aws_vpn_connection.partner[0].id}",
      "--query 'VpnConnections[0].VgwTelemetry[].[OutsideIpAddress,Status,StatusMessage]'",
      "--output table",
    ])
  }
}

output "partner_check" {
  description = "Lenh kiem chung tuyen doi tac - chay TU MAY GIA LAP, khong phai tu day"

  value = !var.enable_partner_vpn ? "" : join("\n", [
    "",
    "1. Duong ham co len khong (doc tu AWS, khong tu state):",
    "   aws ec2 describe-vpn-connections --region ${var.region} \\",
    "     --vpn-connection-ids ${aws_vpn_connection.partner[0].id} \\",
    "     --query 'VpnConnections[0].VgwTelemetry[].[OutsideIpAddress,Status]' --output table",
    "",
    "   AWS chi bao dam MOT trong hai tunnel UP o che do static.",
    "   Ca hai DOWN sau ~5 phut thi vao may gia lap doc log.",
    "",
    "2. Vao may cua doi tac gia lap:",
    "   aws ssm start-session --target ${aws_instance.partner_sim[0].id} --region ${var.region}",
    "",
    "3. Trong session:",
    "   sudo vpn-check                 # SA, interface vti, route",
    "   sudo cat /var/log/user-data.log  # khi vpn-check khong co gi",
    "",
    "4. Goi dich vu ban cong bo - day la phep do that:",
    "   curl -s -o /dev/null -w '%%{http_code}\\n' http://${aws_lb.partner[0].dns_name}/",
    "",
    "   200 nghia la ca tuyen thong: IPsec -> VGW -> NLB -> TGW ->",
    "   firewall -> spoke ${local.partner_target_ip} (account khac).",
    "",
    "5. Kiem lop cach ly - PHAI THAT BAI:",
    "   curl -sm 5 http://${local.partner_target_ip}/",
    "",
    "   Doi tac KHONG duoc goi thang toi spoke. May nay khong co route",
    "   toi dai do, va do la lop kiem soat thu nhat trong ba lop.",
    "",
  ])
}
