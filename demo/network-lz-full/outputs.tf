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
  c_gwlb      = 0.0125
  c_gwlbe     = 0.01
  c_palo_alto = 1.50 # EC2 m5.xlarge (~$0.24) + license (~$1.3)
  c_f5        = 1.50 # EC2 m5.xlarge (~$0.24) + license (~$1.3)

  # MOT attachment moi VPC, khong phu thuoc so AZ - them AZ chi them
  # subnet vao attachment da co.
  # Dem CA spoke noi bo lan remote: moi attachment deu tinh tien nhu nhau.
  n_attach = length(var.spokes) + 1 + local.fw + local.ing

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

    1. Vao EC2 o ${local.first_spoke} (vao duoc = duong egress OK):
       aws ssm start-session --target ${try(aws_instance.test[local.first_spoke].id, "<bat enable_test_instances>")} --region ${var.region}

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
