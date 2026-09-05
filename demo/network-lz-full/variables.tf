variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "availability_zones" {
  description = <<-EOT
    AZ dat ha tang mang. TOI THIEU 2.

    MOI AZ nhan mot ban sao cua:
      NAT Gateway               ~$33/thang + phi du lieu
      Network Firewall endpoint ~$285/thang   <- khoan lon nhat
      subnet tgw/firewall/public/private

    Vi sao khong cho 1 AZ: duong ra Internet VA east-west deu di qua
    security VPC. AZ do hong thi khong phai "giam nang luc" ma la
    MAT CA MANG - spoke A goi spoke B cung chet, du ca hai khong lien
    quan gi toi AZ do.

    3 AZ chi them du phong; bang CIDR o doc 17 muc 3 cap phat du cho 3.
  EOT
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "Toi thieu 2 AZ. Mot AZ nghia la mot diem hong lam sap ca mang - xem mo ta bien."
  }

  validation {
    condition     = length(var.availability_zones) <= 3
    error_message = "Toi da 3 AZ - bang CIDR o doc 17 muc 3 chi cap phat den do."
  }

  validation {
    condition     = length(distinct(var.availability_zones)) == length(var.availability_zones)
    error_message = "availability_zones co phan tu trung nhau."
  }
}

########################################
# Tag chuan - xem doc 11 muc 2
#
# Bon tag nay duoc bat cost allocation o landing-zone/billing-guard.
# Gan chung o day thi Cost Explorer moi group duoc theo tag.
########################################

variable "project" {
  description = "Tag Project, dong thoi la tien to dat ten resource"
  type        = string
  default     = "lz-net"
}

variable "cost_center" {
  description = "Tag CostCenter - ma phong ban chiu chi phi. Dung MA, khong dung ten (doc 11 muc 2)."
  type        = string
  default     = "CC-0000"
}

variable "owner" {
  description = "Tag Owner - email nguoi chiu trach nhiem"
  type        = string
  default     = "platform@example.com"
}

variable "environment" {
  description = "Tag Environment"
  type        = string
  default     = "sandbox"

  validation {
    condition     = contains(["dev", "staging", "prod", "sandbox"], var.environment)
    error_message = "environment phai la dev, staging, prod hoac sandbox."
  }
}

########################################
# CIDR - theo bang chuan o doc 17 muc 3
########################################

variable "ingress_vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "security_vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "egress_vpc_cidr" {
  type    = string
  default = "10.2.0.0/16"
}

variable "spokes" {
  description = <<-EOT
    VPC workload. Moi spoke ton them ~$0.05/gio phi TGW attachment.

    account_id = null (mac dinh)  -> VPC tao NGAY TRONG account nay,
                                     xem vpc-spokes.tf
    account_id = "1234..."        -> VPC tao o ACCOUNT KHAC qua
                                     StackSet, xem vpc-spokes-remote.tf

    Dat account_id doi hoi Terraform chay tu MANAGEMENT ACCOUNT - day
    la rang buoc IAM, khong phai so thich. Xem khoi comment dau file
    vpc-spokes-remote.tf.

    CIDR khai TUONG MINH va di qua review: trung CIDR trong mot luoi
    TGW thi route table khong phan biet duoc hai spoke, va sua thi
    phai xoa VPC. Bang cap phat o doc 17 muc 3:

      NonProd  10.10.0.0/14   (10.10 - 10.13)
      Prod     10.20.0.0/14   (10.20 - 10.23)
      Sandbox  10.60.0.0/14   (khong attach TGW)
  EOT

  type = map(object({
    cidr       = string
    account_id = optional(string)

    # BAT BUOC khi co account_id. StackSet service-managed trien khai
    # theo cay to chuc, nen phai biet account nam o OU nao.
    #   aws organizations list-parents --child-id <account-id>
    ou_id = optional(string)

    # VPC cua spoke nay duoc dung NGOAI StackSet - loi 59.
    #
    # Can cho MANAGEMENT ACCOUNT: StackSet SERVICE_MANAGED trien khai
    # theo cay to chuc va AWS loai management account ra. Khong co
    # thong bao nao noi vay - list-stack-instances chi don gian khong
    # co dong cho account do, con operation thi FAILED.
    #
    # Dat = true thi Terraform bo qua spoke nay khi tao stack instance,
    # nhung VAN share RAM cho no va VAN noi attachment cua no vao route
    # table khi attachment xuat hien.
    #
    # Dung VPC bang tay, tu account do:
    #   terraform output -raw spoke_template > spoke-vpc.json
    #   aws cloudformation create-stack --stack-name <project>-spoke-vpc \
    #     --template-body file://spoke-vpc.json --parameters ...
    manual_vpc = optional(bool, false)
  }))

  default = {
    "app-dev"  = { cidr = "10.10.0.0/16" }
    "app-prod" = { cidr = "10.20.0.0/16" }
  }

  validation {
    condition = alltrue([
      for k, v in var.spokes :
      try(v.account_id, null) == null || can(regex("^[0-9]{12}$", v.account_id))
    ])
    error_message = "account_id phai dung 12 chu so, hoac bo trong de tao tai chinh account nay."
  }

  validation {
    condition = alltrue([
      for k, v in var.spokes :
      try(v.account_id, null) == null || try(v.ou_id, null) != null
    ])
    error_message = "Spoke khai account_id thi phai khai ca ou_id - StackSet service-managed trien khai theo cay to chuc. Lay bang: aws organizations list-parents --child-id <account-id>"
  }
}

variable "ram_use_external_principals" {
  description = <<-EOT
    Cho Terraform tu tao RAM share cho TGW, bang duong EXTERNAL.

    MAC DINH TAT, va no tat vi mot ly do - khong phai vi chua lam xong.

    Duong dung la share trong pham vi to chuc (allow_external_principals
    = false). Trong to chuc nay duong do khong chay: RAM khong phan giai
    duoc o-tvkzhcq3yh, ke ca khi goi tu management account. Loi 56.

    Thi nghiem doi chung, doi DUNG MOT bien:
      --no-allow-external-principals + account ID -> OperationNotPermitted
      --allow-external-principals    + CUNG ID do -> ACTIVE

    Bat bien nay = chon duong vong. Ba he qua:

      1. NOI RAO CHAN. Share nhan duoc principal ngoai to chuc. Danh
         sach account trong var.spokes la thu duy nhat con chan.
      2. MAT TU DONG. Moi spoke account phai chap nhan loi moi mot lan
         - xem ram_invitations_accepted.
      3. LA TAM THOI. Support sua xong thi doi ve false.

    Khong bat, va cung khong share bang CLI (tgw_shared_manually), thi
    StackSet bao "Transit Gateway ... was deleted or does not exist".
  EOT
  type        = bool
  default     = false
}

variable "remote_test_instances" {
  description = <<-EOT
    Tao EC2 kiem chung trong CA spoke o account khac, khong chi spoke
    local.

    De TAT thi khong co gi trong VPC remote de goi tới, va moi phep do
    east-west cross-account deu phai tin vao route table thay vi tin
    vao goi tin.

    IP DUOC GAN CO DINH, khong de AWS cap ngau nhien: .10 cua subnet
    dau tien. Ly do khong phai tham my - Terraform KHONG doc duoc
    output cua stack instance, va verify.sh khong co credential o
    account kia. IP tinh truoc duoc la cach duy nhat de kiem chung
    ma khong phai dang nhap vao tung account.

      VPC 10.20.0.0/16 -> subnet dau 10.20.0.0/24 -> EC2 10.20.0.10

    Moi con ~$0.0116/gio (t3.micro). Ba spoke remote la ~$0.84/ngay.

    CAN CAPABILITY_IAM: template tao IAM role cho SSM, nen stack set
    phai khai capabilities = ["CAPABILITY_IAM"]. Thieu thi
    CreateStackInstances bao InsufficientCapabilities.
  EOT
  type        = bool
  default     = false
}

variable "east_west_mesh_ports" {
  description = <<-EOT
    Port duoc mo giua MOI cap spoke, sinh rule tu dong.

    east_west_rules la khai bao tay tung chieu - dung cho luat that.
    Bien nay dung de THU: mo mot port giua moi cap spoke de do duong
    di, roi doc log xem ai thuc su goi ai.

    De [80] la du cho phep thu: curl duoc = duong thong ca hai chieu.
    Port 22 CO Y khong nam trong day, de chung minh firewall chan duoc
    thu ma security group da mo.

    Rong = khong sinh rule nao, chi dung east_west_rules.
  EOT
  type        = list(number)
  default     = []
}

variable "share_tgw_with_accounts" {
  description = <<-EOT
    Account duoc THAY Transit Gateway, ngoai cac account co spoke.

    Chia se va co VPC la hai viec khac nhau. var.spokes noi "account
    nay se duoc dung mot VPC theo khuon"; bien nay noi "account nay
    duoc phep tu cam vao TGW khi nao ho muon".

    Dung cho account trong LZ chua co spoke nhung se can: security,
    logarchive, hoac mot account sap co workload.

    Lay danh sach:
      aws organizations list-accounts \
        --query 'Accounts[?Status==`ACTIVE`].[Id,Name]' --output text

    KHONG can khai account dang chay code nay - RAM tu choi share cho
    chinh chu so huu, va code da loc no ra.

    Moi account them vao day phai CHAP NHAN LOI MOI mot lan, giong
    het spoke - xem ram_invitations_accepted.

    Chi co tac dung khi ram_use_external_principals = true.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.share_tgw_with_accounts : can(regex("^[0-9]{12}$", a))])
    error_message = "Moi phan tu phai la account ID 12 chu so."
  }
}

variable "ram_invitations_accepted" {
  description = <<-EOT
    Xac nhan MOI spoke account da chap nhan loi moi RAM.

    Chi co y nghia khi ram_use_external_principals = true. Share ngoai
    to chuc khong tu dong duoc chap nhan, va Terraform khong lam ho
    duoc: demo chi co MOT provider, tro vao account network.

    Chay o TUNG spoke account:

      aws ram get-resource-share-invitations --region <region> \
        --query 'resourceShareInvitations[?status==`PENDING`]'
      aws ram accept-resource-share-invitation \
        --resource-share-invitation-arn <arn>

    Kiem tu chinh spoke account - day moi la bang chung that:

      aws ec2 describe-transit-gateways \
        --query 'TransitGateways[].TransitGatewayId'

    Rong = chua nhan. Va day la cho im lang: apply van XANH, share van
    ACTIVE, khong loi nao cho toi khi StackSet khong tim thay TGW.
  EOT
  type        = bool
  default     = false
}

variable "tgw_shared_manually" {
  description = <<-EOT
    Xac nhan da share Transit Gateway cho cac spoke account BANG CLI.

    Terraform khong lam duoc viec nay - loi 55. RAM tu choi
    AssociateResourceShare (ca resource lan principal), va chi chap
    nhan CreateResourceShare kem --resource-arns; ma
    aws_ram_resource_share cua provider khong co thuoc tinh do.

    Lam mot lan, tu account network:

      aws ram create-resource-share --region <region> \
        --name <project>-tgw --no-allow-external-principals \
        --resource-arns <tgw-arn> --principals <spoke-account-id>

    LENH TREN CHUA KIEM CHUNG. Phep do o loi 55 chi chay dang khong
    kem --principals; dang mot-lenh-ca-hai la suy ra. Truoc khi dat
    bien nay = true, kiem bang:

      aws ram list-principals --resource-owner SELF \
        --resource-arns <tgw-arn> --region <region>

    Rong = chua share duoc, du lenh tren khong bao loi.
  EOT
  type        = bool
  default     = false
}

variable "ram_sharing_with_organization_enabled" {
  description = <<-EOT
    Xac nhan da bat RAM sharing voi Organizations o cap to chuc.

    Chay MOT LAN tu MANAGEMENT account:
      aws ram enable-sharing-with-aws-organization

    Chua bat thi AssociateResourceShare bao "Organization o-xxxx could
    not be found" - nghe nhu sai organization_arn, thuc ra la thieu
    buoc nay. Xem loi 52 doc 22.
  EOT
  type        = bool
  default     = false
}

variable "wire_remote_attachments" {
  description = <<-EOT
    Pha 2: noi attachment cua spoke remote vao route table cua TGW.

    Vi sao phai tach lam hai pha - loi 50:
    data source tim attachment loc theo ID cua TGW, ma TGW duoc tao
    trong chinh config nay. Lan apply dau, ID do chua biet nen
    for_each khong dung duoc bo khoa, va plan chet voi
    "Invalid for_each argument".

      false (mac dinh)  pha 1 - tao VPC + attachment o account dich
      true              pha 2 - noi route, chay SAU khi pha 1 xong

    Giua hai pha, attachment ton tai ma khong thuoc route table nao:
    State la 'available', khong loi, khong mot goi tin nao di qua.
  EOT
  type        = bool
  default     = false
}

variable "network_account_is_stackset_delegated_admin" {
  description = <<-EOT
    Xac nhan account dang chay DA duoc dang ky lam delegated
    administrator cua CloudFormation StackSets.

    Chay MOT LAN tu MANAGEMENT account:

      aws organizations register-delegated-administrator \
        --service-principal member.org.stacksets.cloudformation.amazonaws.com \
        --account-id <network-account-id>

    Kiem:
      aws organizations list-delegated-administrators \
        --service-principal member.org.stacksets.cloudformation.amazonaws.com

    DUNG chay ca bo code nay tu management account de khoi phai dang ky.
    Demo chi co MOT provider, nen lam vay se tao TOAN BO hub - TGW,
    security VPC, egress, firewall, NAT, NLB - trong management account,
    noi SCP khong bao gio ap duoc. Xem loi 51 doc 22.

    Bien nay khong doi hanh vi resource nao; no chi de check block noi
    ro nguyen nhan TRUOC khi apply.
  EOT
  type        = bool
  default     = false
}

variable "internal_supernet" {
  description = "Dai bao trum moi VPC noi bo"
  type        = string
  default     = "10.0.0.0/8"
}

########################################
# Cong tac chi phi
########################################

variable "enable_firewall" {
  description = <<-EOT
    false = CHE DO RE (~$0.34/gio). Khong tao security VPC.
            rtb-spokes tro thang sang egress. Kiem chung duoc:
            egress tap trung, cach ly spoke, ingress NLB.
            KHONG kiem chung duoc: east-west qua firewall.

    true  = DAY DU (~$0.74/gio). Network Firewall thanh tra moi luong.
  EOT
  type        = bool
  default     = false
}

variable "firewall_mode" {
  description = "alert = chi ghi log (an toan, dung dau tien). drop = chan that."
  type        = string
  default     = "alert"

  validation {
    condition     = contains(["alert", "drop"], var.firewall_mode)
    error_message = "firewall_mode phai la 'alert' hoac 'drop'."
  }
}

########################################
# DOI TAC - 3rd-party VPC + Site-to-Site VPN (doc 16)
########################################

variable "enable_partner_vpn" {
  description = <<-EOT
    Dung 3rd-party VPC + VPN toi mot doi tac GIA LAP.

    Sinh ra:
      - 3rd-party VPC (vung dem) + VGW + private NAT + NLB noi bo
      - rtb-partner: bang route table thu NAM cua TGW
      - partner-sim VPC + EC2 strongSwan lam dau kia duong ham

    Duong ham LEN THAT, nen do duoc ca tuyen. Xem partner.tf.

    Them ~$0.21/gio: VPN connection $0.05, private NAT $0.045,
    NLB $0.045 (2 AZ), TGW attachment $0.05, EC2 $0.012.

    CAN enable_firewall = true. Khong co thanh tra thi luu luong doi
    tac di thang toi spoke, va lop kiem soat thu ba - lop duy nhat
    nhin duoc tung cap IP/port - khong ton tai.
  EOT
  type        = bool
  default     = false
}

variable "partner_vpc_cidr" {
  description = "3rd-party VPC (vung dem). Nam TRONG internal_supernet."
  type        = string
  default     = "10.9.0.0/16"
}

variable "partner_sim_cidr" {
  description = <<-EOT
    Dai mang cua doi tac gia lap.

    PHAI NGOAI internal_supernet. Trung thi route tinh toi dai doi tac
    se giam len propagation cua spoke trong rtb-security, va TGW khong
    phan biet duoc hai ben - xem check "partner_cidr_does_not_overlap_lz".

    Day chinh la bai toan "CIDR trung nhau" cua doc 16 muc 6, nhung o
    mot cho ma private NAT KHONG giai duoc: NAT doi dia chi phia ben
    kia duong ham, no khong lam hai dai het giam nhau trong bang route
    cua ban.
  EOT
  type        = string
  default     = "172.16.0.0/16"
}

variable "partner_service_port" {
  description = "Cong doi tac goi vao NLB. Ghi ro tung cong trong hop dong ky thuat - doc 16 muc 6."
  type        = number
  default     = 80
}

variable "partner_bgp_asn" {
  description = "ASN phia doi tac. Dai rieng 64512-65534. Khong dung BGP nhung AWS van doi khai."
  type        = number
  default     = 65010
}

variable "partner_amazon_asn" {
  description = "ASN phia AWS cua VGW. Khai ro de tai lieu dua cho doi tac khop voi thuc te."
  type        = number
  default     = 64512
}

variable "partner_tunnel_inside_cidrs" {
  description = <<-EOT
    Dia chi trong hai duong ham, dai 169.254.0.0/16 va PHAI la /30.

    Khai tuong minh chu khong de AWS tu chon: cau hinh strongSwan nhung
    nhung dia chi nay vao user_data, nen moi lan AWS chon lai la mot
    lan cau hinh lech ma khong ai doi gi.

    AWS gio rieng vai dai trong 169.254.0.0/16 (vi du 169.254.169.252/30),
    khai trung se bi tu choi luc tao VPN connection.
  EOT
  type        = list(string)
  default     = ["169.254.100.0/30", "169.254.100.4/30"]

  validation {
    condition     = length(var.partner_tunnel_inside_cidrs) == 2
    error_message = "Phai dung HAI dai - AWS luon tao hai duong ham, khong bat duoc mot."
  }
}

variable "ops_rule_group_arns" {
  description = <<-EOT
    CHO CAM cho lop van hanh (thu muc ops/).

    Bai toan: mo mot port giua hai app la viec HANG NGAY, nhung
    east_west_rules nam trong chinh layer so huu firewall, TGW va moi
    VPC. Sua no nghia la chay `terraform apply` tren layer do - mot
    plan cham vao 200+ resource chi de them mot dong rule. Khong ai
    duyet noi mot plan nhu vay moi ngay, va mot ngay nao do co nguoi
    bam yes qua nhanh.

    Lop ops/ co state RIENG. No tao rule group cua no, va bien nay la
    cho duy nhat hai lop cham nhau: mot danh sach ARN.

    BOOTSTRAP hai buoc, chi lam MOT LAN:

      1. cd ops/ && terraform apply     -> tao rule group, in ra ARN
      2. dien ARN do vao day, apply layer nay -> policy tro toi no

    Tu do ve sau, them/sua/xoa rule chi cham vao ops/: ARN khong doi,
    chi rules_string ben trong doi. Layer nay khong can apply nua.

    Priority bat dau tu 150: sau east_west (100, chua cac luong HA TANG
    nhu NLB->app va SSM->endpoint) va truoc egress_domains (200). Rule
    ha tang phai duoc doc truoc - lop ops khong duoc quyen lam mat SSM.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for a in var.ops_rule_group_arns :
      can(regex("^arn:aws[a-z-]*:network-firewall:", a))
    ])
    error_message = "ops_rule_group_arns phai la ARN cua Network Firewall rule group. Lay bang: cd ops && terraform output -raw rule_group_arn"
  }

  validation {
    condition     = length(var.ops_rule_group_arns) == length(distinct(var.ops_rule_group_arns))
    error_message = "ops_rule_group_arns co ARN trung. Hai stateful_rule_group_reference cung ARN thi CreateFirewallPolicy bi tu choi."
  }
}

variable "enable_ingress" {
  description = "Ingress VPC + NLB. Palo Alto va F5 KHONG co trong demo nay - xem README."
  type        = bool
  default     = true
}

variable "enable_cdn" {
  description = <<-EOT
    CloudFront + AWS WAF truoc NLB. Can enable_ingress = true.

    Chi phi gan nhu $0 (CloudFront free tier 1TB + 10 trieu req/thang;
    WAF ~$5/thang Web ACL + ~$1/thang moi rule group, chia theo gio).
    Phien 4 tieng khoang $0.05.

    CAI GIA THAT: apply cham ~5-15 phut, destroy cham ~15-20 phut
    vi CloudFront phai disable truoc khi delete.

    Bat len cung KHOA ORIGIN: NLB chi nhan traffic tu CloudFront.
  EOT
  type        = bool
  default     = false
}

variable "waf_mode" {
  description = "count = chi dem, khong chan (dung dau tien). block = chan that."
  type        = string
  default     = "count"

  validation {
    condition     = contains(["count", "block"], var.waf_mode)
    error_message = "waf_mode phai la 'count' hoac 'block'."
  }
}

variable "waf_managed_rule_groups" {
  description = "Managed rule group cua AWS. Moi cai ~$1/thang."
  type        = list(string)

  default = [
    "AWSManagedRulesCommonRuleSet",         # OWASP co ban
    "AWSManagedRulesKnownBadInputsRuleSet", # payload khai thac da biet
    "AWSManagedRulesSQLiRuleSet",           # SQL injection
  ]
}

variable "waf_rate_limit" {
  description = "So request toi da tu mot IP trong 5 phut. Toi thieu 100."
  type        = number
  default     = 2000
}

variable "cdn_price_class" {
  description = "PriceClass_100 = US/EU (re nhat). PriceClass_200 = them chau A (do tre tot hon tu VN). PriceClass_All = toan cau."
  type        = string
  default     = "PriceClass_200"
}

variable "enable_interface_endpoints" {
  description = "Interface endpoint trong security VPC (~$0.01/gio moi cai). Can enable_firewall=true."
  type        = bool
  default     = false
}

variable "interface_endpoint_services" {
  type    = list(string)
  default = ["ssm", "ssmmessages", "ec2messages"]
}

########################################
# Palo Alto + F5 — PHASE SAU
#
# Mac dinh TAT. Code viet san de terraform plan kiem chung duoc,
# khi co license chi bat bien nay len.
########################################

variable "enable_appliances" {
  description = <<-EOT
    Palo Alto (qua GWLB) + F5 BIG-IP. Can enable_ingress = true.

    false (mac dinh) -> khong tao gi. IGW -> NLB -> app.
    true             -> IGW -> GWLBe -> PA -> NLB -> F5 -> TGW -> app.

    CHUA APPLY DUOC neu chua subscribe AMI tren Marketplace.

    Muon PLAN ma chua subscribe: dat pa_ami_id va f5_ami_id bang
    mot AMI bat ky, plan se bo qua data source tim AMI Marketplace.

    Chi phi khi bat: ~$3-6/gio (license tinh theo gio).
  EOT
  type        = bool
  default     = false
}

variable "pa_ami_id" {
  description = "AMI cua Palo Alto. De trong = tu tim tren Marketplace theo pa_ami_name_pattern."
  type        = string
  default     = ""
}

variable "pa_ami_name_pattern" {
  description = "Mau ten AMI Palo Alto tren Marketplace"
  type        = string
  default     = "PA-VM-AWS-11.1*"
}

variable "pa_instance_type" {
  description = "Palo Alto can toi thieu m5.xlarge"
  type        = string
  default     = "m5.xlarge"
}

variable "pa_health_check_port" {
  description = "Port health check cua GWLB toi PA. Kiem tra tai lieu PA cho phien ban ban dung."
  type        = number
  default     = 80
}

variable "pa_health_check_protocol" {
  type    = string
  default = "TCP"
}

variable "f5_ami_id" {
  description = "AMI cua F5. De trong = tu tim tren Marketplace theo f5_ami_name_pattern."
  type        = string
  default     = ""
}

variable "f5_ami_name_pattern" {
  description = <<-EOT
    Mau ten AMI F5. Ban PAYG tinh theo gio (khong can mua license truoc)
    thuong co chu 'PAYG' trong ten; ban BYOL co chu 'BYOL'.
    Xem doc 18 muc 0.
  EOT
  type        = string
  default     = "F5 BIGIP-17.1*PAYG-Adv WAF Plus 25Mbps*"
}

variable "f5_instance_type" {
  description = "F5 Advanced WAF can toi thieu m5.xlarge"
  type        = string
  default     = "m5.xlarge"
}

variable "nlb_listener_port" {
  description = "Port NLB nghe. Demo dung 80; production dung 443 voi F5 terminate TLS."
  type        = number
  default     = 80
}

variable "enable_test_instances" {
  description = "EC2 nginx trong moi spoke de kiem chung (~$0.012/gio moi cai)"
  type        = bool
  default     = true
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "partner_sim_ami_ssm_parameter" {
  description = <<-EOT
    AMI cho may gia lap doi tac. UBUNTU, khong phai Amazon Linux.

    VI SAO KHONG DUNG AL2023 NHU MOI MAY KHAC TRONG BO NAY

    AL2023 KHONG CO goi strongswan. Khong phai ten khac, khong phai
    phien ban khac - `dnf install strongswan` tra ve "Unable to find a
    match". AWS cat rat nhieu goi mang khoi repo AL2023.

    Ubuntu co strongswan trong `main`, va do cung la nen tang AWS dung
    trong tai lieu cau hinh VPN cua ho. Doi AMI re hon nhieu so voi
    viet lai cau hinh IPsec cho libreswan.

    Day la may DUY NHAT trong bo nay chay Ubuntu. Neu ban them lenh
    dnf/yum vao user_data cua no, no se hong.

    De thanh bien de doi duoc sang ban khac ma khong phai sua code -
    va de mot duong dan tham so sai bao loi ngay o apply, thay vi
    thanh mot AMI khong ai ngo.
  EOT

  type    = string
  default = "/aws/service/canonical/ubuntu/server/jammy/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

########################################
# Rule east-west - DAY LA PHAN DE THU NGHIEM
########################################

variable "east_west_rules" {
  description = <<-EOT
    Cac luong spoke-to-spoke DUOC PHEP.

    Chu y: khong can them ROUTE nao cho cac luong nay.
    Route 0.0.0.0/0 -> security da phu san. Chi can rule firewall + security group.
    Bo mot dong o day roi apply lai -> luong do bi chan ngay.
  EOT

  type = list(object({
    from_cidr = string
    to_cidr   = string
    port      = number
    note      = string
  }))

  default = [
    {
      from_cidr = "10.10.0.0/16"
      to_cidr   = "10.20.0.0/16"
      port      = 80
      note      = "app-dev goi app-prod qua HTTP"
    },
  ]
}

variable "egress_allowed_domains" {
  description = "Domain duoc phep ra Internet (khop theo TLS SNI / HTTP Host)"
  type        = list(string)

  default = [
    ".amazonaws.com",
    ".amazonlinux.com", # can cho dnf install nginx
    ".amazontrust.com",
  ]
}

########################################
# DUNG DEMO NAY LAM HA TANG THUONG TRUC
########################################

variable "ephemeral" {
  description = <<-EOT
    true (mac dinh) - day la DEMO: dung len xem roi xoa.

      - moi resource mang tag Ephemeral = "true"
      - teardown.sh QUET THEO TAG DO va xoa sach
      - firewall tat delete_protection
      - ba bucket dat force_destroy = true

    Bon dieu do lam cho "dung - xem - xoa" chay tron. Chung cung lam
    cho bo nay CUC KY NGUY HIEM neu ban giu no lai lam mang that:
    mot lenh ./teardown.sh la mat toan bo, khong co lop chan nao.

    false - dung bo nay lam ha tang thuong tru:

      - BO tag Ephemeral -> teardown.sh khong con thay resource nao
      - BAT delete_protection va subnet_change_protection cua firewall
      - force_destroy = false -> bucket con object thi destroy dung lai

    Doi sang false thi terraform destroy se KHONG chay tron nua. Do
    la dung y muon - xem muc "Xoa" trong README.
  EOT
  type        = bool
  default     = true
}

variable "ingress_allowed_cidrs" {
  description = <<-EOT
    Dai IP duoc phep goi vao NLB cong 80, khi enable_cdn = false.

    Mac dinh 0.0.0.0/0 - dung cho demo va CHI dung cho demo: do la mot
    cong HTTP cong khai, khong CDN, khong WAF, khong TLS.

    Giu bo nay lam mang that thi co hai duong:
      - siet lai day, vi du ["<IP-van-phong>/32"]
      - hoac enable_cdn = true, luc do rule nay khong ton tai va chi
        prefix list cua CloudFront vao duoc

    Co check block canh bao khi ephemeral = false ma van de 0.0.0.0/0.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.ingress_allowed_cidrs) > 0
    error_message = "ingress_allowed_cidrs rong thi khong ai vao duoc NLB - dung enable_ingress = false neu do la y muon."
  }
}

########################################
# DNS TAP TRUNG - doc 12
########################################

variable "enable_internal_dns" {
  description = <<-EOT
    PHZ noi bo de dat ten cho service, thay vi goi nhau bang IP.

    Huu ich NGAY ca o mot account: IP doi moi lan thay instance, ten
    thi khong. Gan nhu mien phi - Route 53 tinh $0.50/thang moi hosted
    zone, cong phi truy van.
  EOT
  type        = bool
  default     = true
}

variable "internal_dns_domain" {
  description = <<-EOT
    Ten mien cho PHZ noi bo.

    DUNG duoi TLD cong khai (.com/.net/.org) tru khi ban THAT SU so
    huu ten do: PHZ che mat ten that voi moi VPC duoc gan, nen
    "example.com" trong PHZ se lam moi VPC mat duong toi example.com
    that. Dung .internal hoac .lan.
  EOT
  type        = string
  default     = "lz.internal"

  validation {
    condition     = can(regex("^[a-z0-9.-]+$", var.internal_dns_domain))
    error_message = "internal_dns_domain chi gom chu thuong, so, dau cham va gach ngang."
  }
}

variable "enable_dns_profile" {
  description = <<-EOT
    Route 53 Profile - gom nhieu PHZ lai, share mot lan.

    Mac dinh TAT, va o bo MOT ACCOUNT nay nen giu vay: ca ba VPC deu
    da co PHZ gan thang, profile khong them gi ngoai phi association.

    Chi bat khi:
      - muon thu truoc mo hinh se dung o multi-account, hoac
      - se co VPC o account khac noi vao (can organization_arn)

    GIOI HAN: mot VPC chi gan duoc MOT profile. Gom het vao mot cai.
    Can AWS provider >= 5.60.
  EOT
  type        = bool
  default     = false
}

variable "organization_arn" {
  description = <<-EOT
    ARN to chuc, de share DNS profile qua RAM.

      aws organizations describe-organization --query 'Organization.Arn' --output text

    De rong = khong share. Profile van chay trong chinh account nay.
  EOT
  type        = string
  default     = ""
}

########################################
# PALO ALTO - BOOTSTRAP
########################################

variable "pa_key_name" {
  description = <<-EOT
    Ten EC2 key pair de dang nhap Palo Alto lan dau.

    VM-Series tren AWS KHONG co mat khau mac dinh: lan dau vao bang
    `ssh -i <key>.pem admin@<ip mgmt>`, roi tu dat mat khau. Bootstrap
    o day CO CHU DICH khong dat mat khau - mot phash viet san trong
    XML nam trong S3 va trong state, va no se song lau hon y dinh cua
    nguoi viet no.

    De trong thi instance van tao duoc nhung KHONG AI VAO DUOC. Chap
    nhan duoc khi chi chay plan de kiem code; khong chap nhan duoc khi
    apply that.
  EOT
  type        = string
  default     = ""
}

variable "pa_mgmt_allowed_cidrs" {
  description = <<-EOT
    Dai duoc phep goi vao giao dien quan tri cua Palo Alto.

    Vao CA security group LAN `permitted-ip` trong bootstrap.xml -
    hai lop, va lop thu hai la lop duy nhat con tac dung neu ai do noi
    long security group.

    MAC DINH LA DAI NOI BO, khong phai 0.0.0.0/0. Mo giao dien quan
    tri cua mot firewall ra Internet la cach nhanh nhat de bien thiet
    bi bao ve thanh duong vao.
  EOT
  type        = list(string)
  default     = ["10.0.0.0/8"]

  validation {
    condition     = !contains(var.pa_mgmt_allowed_cidrs, "0.0.0.0/0")
    error_message = "pa_mgmt_allowed_cidrs khong duoc chua 0.0.0.0/0 - do la giao dien quan tri cua firewall."
  }
}

variable "pa_panos_version" {
  description = "Phien ban PAN-OS ghi vao thuoc tinh version cua bootstrap.xml. PHAI khop AMI dang dung."
  type        = string
  default     = "11.1.0"
}

variable "pa_zone_name" {
  description = "Ten security zone chua interface du lieu"
  type        = string
  default     = "inspect"
}

variable "pa_allowed_applications" {
  description = <<-EOT
    App-ID duoc cho qua trong rule dau tien.

    Khai bang TEN UNG DUNG, khong phai cong. Do la ca ly do dung Palo
    Alto thay vi mot ACL: `web-browsing` tren cong 8080 van duoc nhan
    ra, con mot ket noi SSH nguy trang thanh cong 443 thi khong.
  EOT
  type        = list(string)
  default     = ["web-browsing", "ssl"]
}

variable "pa_security_profile_group" {
  description = <<-EOT
    Nhom profile bao mat gan vao rule cho qua.

    "best-practice" la nhom dung san trong PAN-OS 10.0 tro len. Cho
    qua ma khong gan profile nao thi firewall chi lam viec cua mot
    ACL - dung thu ma khong ai muon tra $1.3/gio de co.
  EOT
  type        = string
  default     = "best-practice"
}

variable "pa_default_action" {
  description = <<-EOT
    Hanh dong cua rule CUOI CUNG: "allow" hay "deny".

    Bat dau bang "allow" de doc log truoc - cung ly do voi
    firewall_mode = "alert" cua Network Firewall. Chuyen sang "deny"
    khi da biet cai gi that su di qua.
  EOT
  type        = string
  default     = "allow"

  validation {
    condition     = contains(["allow", "deny", "drop", "reset-both"], var.pa_default_action)
    error_message = "pa_default_action phai la allow, deny, drop hoac reset-both."
  }
}
