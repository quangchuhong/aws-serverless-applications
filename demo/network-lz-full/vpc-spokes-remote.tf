########################################
# SPOKE O ACCOUNT KHAC - VPC + attachment + route, tu dong
#
# Spoke trong vpc-spokes.tf nam CUNG ACCOUNT voi TGW. File nay lo
# truong hop spoke nam o ACCOUNT KHAC trong to chuc - dung mo hinh
# that cua Landing Zone.
#
# ---------------------------------------------------------------
# CHAY TU ACCOUNT NETWORK - KHONG PHAI MANAGEMENT. Loi 51.
#
# Ban dau file nay yeu cau chay tu MANAGEMENT ACCOUNT, vi StackSet
# SERVICE_MANAGED chi tao duoc tu do. Do la mot nua su that, va nua
# con lai lam hong ca thiet ke:
#
#   Demo chi co MOT provider. Chay tu management nghia la TOAN BO hub -
#   TGW, security VPC, egress VPC, firewall, NAT, NLB - deu duoc tao
#   trong MANAGEMENT ACCOUNT.
#
# Management account giu Organizations, SCP va hoa don, va la account
# duy nhat SCP KHONG BAO GIO ap duoc. Dat ha tang mang o do la dat no
# ngoai moi guardrail cua chinh to chuc.
#
# CACH DUNG: dang ky account network lam DELEGATED ADMINISTRATOR cua
# CloudFormation StackSets. Chay MOT LAN tu management account:
#
#   aws organizations register-delegated-administrator \
#     --service-principal member.org.stacksets.cloudformation.amazonaws.com \
#     --account-id <network-account-id>
#
# Sau do StackSet tao duoc tu chinh account network voi
# call_as = "DELEGATED_ADMIN", va hub o dung cho.
#
# Kiem:
#   aws organizations list-delegated-administrators \
#     --service-principal member.org.stacksets.cloudformation.amazonaws.com
#
# ---------------------------------------------------------------
# VI SAO STACKSET CHU KHONG PHAI PROVIDER ALIAS
#
# Provider KHONG sinh dong duoc bang for_each. Moi account la mot khoi
# provider viet tay, va account thu bay la sua code - dung ly do
# landing-zone/network/README.md tu choi cach do.
#
# StackSet nhan danh sach account lam tham so, nen for_each chay duoc
# va them account = them mot dong trong bien.
#
# ---------------------------------------------------------------
# VI SAO NHAM TUNG ACCOUNT, KHONG NHAM OU
#
# Nham OU + auto_deployment thi account moi tu duoc trien khai - nghe
# hay hon. Nhung luc do CIDR phai TU SINH, va trung CIDR trong mot
# luoi TGW la thu rat kho go: hai spoke cung dai thi route table khong
# phan biet duoc, va sua thi phai xoa VPC.
#
# Nen CIDR o day khai tuong minh va di qua review. Phan tu sinh de lai
# cho luc lam account vending (kieu AFT), noi CIDR duoc cap cung luc
# account duoc tao.
########################################

locals {
  # Spoke co account_id => nam o account khac.
  remote_spokes = {
    for k, v in var.spokes : k => v
    if try(v.account_id, null) != null && v.account_id != data.aws_caller_identity.current.account_id
  }

  has_remote = length(local.remote_spokes) > 0

  # Spoke ma StackSet dung duoc.
  #
  # MANAGEMENT ACCOUNT KHONG NAM TRONG DAY - loi 59. StackSet
  # SERVICE_MANAGED trien khai theo cay to chuc va AWS loai management
  # account ra khoi cac dot trien khai do. Cach no bao loi rat te:
  #
  #   list-stack-instances  -> KHONG co dong nao cho account do
  #   operation             -> FAILED
  #   provider AWS          -> "last error: %!s(<nil>)"
  #
  # Khong mot cho nao noi "management account khong duoc ho tro". Ba
  # dau hieu, khong dau hieu nao chi dung cho.
  #
  # Dat manual_vpc = true cho spoke do, roi dung VPC bang stack THUONG
  # chay tai cho - xem output "spoke_template".
  stackset_spokes = {
    for k, v in local.remote_spokes : k => v
    if !try(v.manual_vpc, false)
  }

  # IP CUA EC2 TEST TRONG SPOKE REMOTE - tinh truoc, khong hoi sau.
  #
  # Template CloudFormation chia VpcCidr thanh 4 subnet /24 bang
  # Fn::Cidr(VpcCidr, 4, 8); PrivateA la khoi dau. Cong thuc duoi day
  # phai KHOP voi cach chia do:
  #
  #   10.20.0.0/16 -> [10.20.0.0/24, 10.20.1.0/24, 10.20.2.0/24, 10.20.3.0/24]
  #   -> PrivateA = 10.20.0.0/24 -> host thu 10 = 10.20.0.10
  #
  # Doi cach chia subnet trong template ma quen sua day thi moi phep
  # kiem east-west se curl vao mot dia chi khong co ai o do - va bao
  # "khong thong" cho mot mang hoan toan binh thuong.
  remote_test_ips = !var.remote_test_instances ? {} : {
    for k, v in local.stackset_spokes :
    k => cidrhost(cidrsubnets(v.cidr, 8, 8, 8, 8)[0], 10)
  }

  # PHA HAI - xem khoi "HAI PHA" o cuoi file.
  wire = local.has_remote && var.wire_remote_attachments

  # Spoke KHONG khai account_id => tao ngay trong account nay.
  #
  # MOI resource cua spoke noi bo phai for_each tren local NAY, khong
  # phai var.spokes. Ban dau chung deu dung var.spokes, nen mot spoke
  # khai account_id se duoc tao HAI LAN: mot VPC local o day va mot
  # VPC remote qua StackSet - trung CIDR, trung attachment, gap doi
  # tien. Xem loi 49 doc 22.
  local_spokes = {
    for k, v in var.spokes : k => v
    if try(v.account_id, null) == null || v.account_id == data.aws_caller_identity.current.account_id
  }
}

########################################
# 1. Share TGW cho cac spoke account
#
# MAC DINH TAT. Bat bang ram_use_external_principals = true.
#
# ---------------------------------------------------------------
# VI SAO PHAI BAT BANG TAY, VA VI SAO NO KHONG PHAI LUA CHON DEP
#
# Duong dung la share trong pham vi to chuc: allow_external_principals
# = false, principal la account ID hoac OU. Trong to chuc nay duong do
# KHONG chay - RAM khong phan giai duoc o-tvkzhcq3yh. Loi 56.
#
# Thi nghiem doi chung, cung management account, cung principal, cung
# phut, doi DUNG MOT bien:
#
#   --no-allow-external-principals  account ID trong org -> OperationNotPermitted
#   --no-allow-external-principals  OU ARN day du        -> unknown organization
#   --allow-external-principals     CUNG account ID do   -> ACTIVE
#   --allow-external-principals     associate them mot   -> ASSOCIATING, external:true
#
# Dong cuoi la bang chung truc tiep nhat: RAM danh dau mot account DANG
# O TRONG to chuc la "external". Nen day khong phai cach lam dung, ma
# la duong vong quanh mot thu dang hong phia AWS.
#
# ---------------------------------------------------------------
# BA HE QUA PHAI BIET TRUOC KHI BAT
#
# 1. NOI RAO CHAN. allow_external_principals = true nghia la share nay
#    VE NGUYEN TAC nhan duoc principal ngoai to chuc. Ranh gioi to chuc
#    khong con bao ve; danh sach account trong var.spokes tro thanh thu
#    duy nhat chan. Sai mot account ID la share TGW ra ngoai.
#
# 2. MAT TU DONG. Share ngoai to chuc KHONG tu dong duoc chap nhan. Moi
#    spoke account phai chay MOT LAN:
#
#      aws ram get-resource-share-invitations --region <region>
#      aws ram accept-resource-share-invitation \
#        --resource-share-invitation-arn <arn>
#
#    Demo nay chi co MOT provider nen Terraform khong chap nhan ho duoc.
#    Chua chap nhan thi StackSet o muc 2 bao:
#      "Transit Gateway tgw-xxx was deleted or does not exist"
#    - mot cau khong nhac gi toi RAM.
#
# 3. LA TAM THOI. Khi AWS Support sua duoc phan phan giai to chuc, doi
#    ram_use_external_principals ve false va thay principal bang OU ARN
#    hoac giu account ID - luc do share tu dong duoc chap nhan va muc 2
#    o tren bien mat. Doi mot dong, khong phai viet lai.
########################################

locals {
  # Share can ton tai khi co spoke remote HOAC khi chi muon cho account
  # khac thay TGW ma chua dung VPC nao. Rang buoc vao has_remote thoi
  # thi share_tgw_with_accounts se im lang khong lam gi - dung cai bay
  # "khai bien ma khong co tac dung".
  ram_needed = local.has_remote || length(var.share_tgw_with_accounts) > 0
  ram_share  = local.ram_needed && var.ram_use_external_principals ? 1 : 0
}

resource "aws_ram_resource_share" "tgw" {
  count = local.ram_share

  name = "${var.project}-tgw"

  # true CHI vi loi 56. Xem ba he qua o tren.
  allow_external_principals = true

  tags = { Name = "${var.project}-tgw" }
}

resource "aws_ram_resource_association" "tgw" {
  count = local.ram_share

  resource_arn       = aws_ec2_transit_gateway.hub.arn
  resource_share_arn = aws_ram_resource_share.tgw[0].arn
}

# Mot principal moi account - KHONG share cho ca to chuc.
#
# Hai nguon gop lai:
#   var.spokes                  account se duoc dung VPC theo khuon
#   var.share_tgw_with_accounts account chi duoc THAY TGW, tu cam sau
#
# distinct() vi hai spoke cung nam trong mot account la chuyen binh
# thuong (vi du app-prod va app-uat), va associate cung mot principal
# hai lan thi RAM tra ve loi trung.
#
# Loai account dang chay code nay: RAM tu choi share cho chinh chu so
# huu, va de lot vao day thi apply chet o mot loi khong noi ro vi sao.
locals {
  ram_principals = local.ram_share == 0 ? [] : [
    for a in distinct(concat(
      [for v in local.remote_spokes : v.account_id],
      var.share_tgw_with_accounts,
    )) : a if a != data.aws_caller_identity.current.account_id
  ]
}

resource "aws_ram_principal_association" "spoke_accounts" {
  for_each = toset(local.ram_principals)

  principal          = each.value
  resource_share_arn = aws_ram_resource_share.tgw[0].arn
}

########################################
# 2. StackSet: VPC + subnet + route table + attachment
#
# CloudFormation chay TRONG account dich, nen no tao duoc thu ma
# Terraform o day khong voi toi.
#
# Attachment tao tu phia account dich se duoc TGW TU DONG CHAP NHAN
# nho auto_accept_shared_attachments = "enable" tren TGW. Thieu cai do
# thi attachment nam o trang thai pendingAcceptance vinh vien - khong
# loi, khong canh bao, va khong mot goi tin nao di qua.
########################################

resource "aws_cloudformation_stack_set" "spoke" {
  count = local.has_remote ? 1 : 0

  name             = "${var.project}-spoke-vpc"
  description      = "VPC + TGW attachment cho spoke o account khac"
  permission_model = "SERVICE_MANAGED"

  # CAPABILITY_IAM can khi remote_test_instances = true: template tao
  # IAM role + instance profile cho SSM. Thieu thi
  # CreateStackInstances bao InsufficientCapabilitiesException, va cau
  # do khong noi ro resource nao doi quyen gi.
  #
  # Khai san ca hai truong hop de khong phai doi stack set khi bat/tat
  # EC2 test - khai them capability KHONG tu tao IAM resource nao.
  capabilities = ["CAPABILITY_IAM"]

  # DELEGATED_ADMIN: goi tu account network da duoc uy quyen, KHONG
  # phai tu management. Xem khoi comment dau file - loi 51.
  call_as = "DELEGATED_ADMIN"

  # Khong bat auto_deployment: account moi vao OU se KHONG tu co VPC.
  # Co y - xem khoi comment dau file ve CIDR.
  auto_deployment {
    enabled = false
  }

  parameters = {
    VpcCidr          = "10.10.0.0/16"
    TransitGatewayId = aws_ec2_transit_gateway.hub.id
    AzA              = var.availability_zones[0]
    AzB              = length(var.availability_zones) > 1 ? var.availability_zones[1] : var.availability_zones[0]
    ProjectName      = var.project
    SpokeName        = "spoke"
    DnsProfileId     = var.enable_dns_profile ? aws_route53profiles_profile.shared[0].id : ""
    TestPrivateIp    = ""
    TestInstanceType = var.instance_type
    InternalSupernet = var.internal_supernet
  }

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    # CHI ASCII - loi 54.
    #
    # CloudFormation luu lai chuoi nay voi "?" thay cho dau tieng Viet,
    # nen Terraform thay khac va doi sua o MOI lan plan; CloudFormation
    # lai bop meo tiep. Mot diff khong bao gio hoi tu, cung ho voi
    # loi 39 va 42.
    #
    # Cung khop quy uoc cua repo: comment trong code khong dau.
    Description = "Spoke VPC noi vao Transit Gateway trung tam"

    Parameters = {
      VpcCidr          = { Type = "String" }
      TransitGatewayId = { Type = "String" }
      AzA              = { Type = "String" }
      AzB              = { Type = "String" }
      ProjectName      = { Type = "String" }
      SpokeName        = { Type = "String" }
      DnsProfileId     = { Type = "String", Default = "" }

      # EC2 kiem chung - de rong la khong tao
      TestPrivateIp    = { Type = "String", Default = "" }
      TestInstanceType = { Type = "String", Default = "t3.micro" }
      InternalSupernet = { Type = "String", Default = "10.0.0.0/8" }
    }

    Conditions = {
      HasDnsProfile   = { "Fn::Not" = [{ "Fn::Equals" = [{ Ref = "DnsProfileId" }, ""] }] }
      HasTestInstance = { "Fn::Not" = [{ "Fn::Equals" = [{ Ref = "TestPrivateIp" }, ""] }] }
    }

    Resources = {
      Vpc = {
        Type = "AWS::EC2::VPC"
        Properties = {
          CidrBlock          = { Ref = "VpcCidr" }
          EnableDnsSupport   = true
          EnableDnsHostnames = true
          Tags               = [{ Key = "Name", Value = { "Fn::Sub" = "$${ProjectName}-$${SpokeName}-vpc" } }]
        }
      }

      # Subnet private: noi dat workload. KHONG co duong ra Internet
      # rieng - moi thu di qua TGW.
      PrivateA = {
        Type = "AWS::EC2::Subnet"
        Properties = {
          VpcId            = { Ref = "Vpc" }
          AvailabilityZone = { Ref = "AzA" }
          CidrBlock        = { "Fn::Select" = [0, { "Fn::Cidr" = [{ Ref = "VpcCidr" }, 4, 8] }] }
          Tags             = [{ Key = "Name", Value = { "Fn::Sub" = "$${ProjectName}-$${SpokeName}-private-a" } }]
        }
      }
      PrivateB = {
        Type = "AWS::EC2::Subnet"
        Properties = {
          VpcId            = { Ref = "Vpc" }
          AvailabilityZone = { Ref = "AzB" }
          CidrBlock        = { "Fn::Select" = [1, { "Fn::Cidr" = [{ Ref = "VpcCidr" }, 4, 8] }] }
          Tags             = [{ Key = "Name", Value = { "Fn::Sub" = "$${ProjectName}-$${SpokeName}-private-b" } }]
        }
      }

      # Subnet rieng cho ENI cua TGW attachment. Tach ra de route table
      # cua workload khong dinh gi toi duong cua TGW.
      TgwA = {
        Type = "AWS::EC2::Subnet"
        Properties = {
          VpcId            = { Ref = "Vpc" }
          AvailabilityZone = { Ref = "AzA" }
          CidrBlock        = { "Fn::Select" = [2, { "Fn::Cidr" = [{ Ref = "VpcCidr" }, 4, 8] }] }
          Tags             = [{ Key = "Name", Value = { "Fn::Sub" = "$${ProjectName}-$${SpokeName}-tgw-a" } }]
        }
      }
      TgwB = {
        Type = "AWS::EC2::Subnet"
        Properties = {
          VpcId            = { Ref = "Vpc" }
          AvailabilityZone = { Ref = "AzB" }
          CidrBlock        = { "Fn::Select" = [3, { "Fn::Cidr" = [{ Ref = "VpcCidr" }, 4, 8] }] }
          Tags             = [{ Key = "Name", Value = { "Fn::Sub" = "$${ProjectName}-$${SpokeName}-tgw-b" } }]
        }
      }

      Attachment = {
        Type = "AWS::EC2::TransitGatewayAttachment"
        Properties = {
          TransitGatewayId = { Ref = "TransitGatewayId" }
          VpcId            = { Ref = "Vpc" }
          SubnetIds        = [{ Ref = "TgwA" }, { Ref = "TgwB" }]
          # Tag nay la thu Terraform dung de TIM LAI attachment o muc 3.
          # Doi format tag = hong phan noi route table.
          Tags = [{ Key = "Name", Value = { "Fn::Sub" = "$${ProjectName}-tgwa-$${SpokeName}" } }]
        }
      }

      PrivateRt = {
        Type = "AWS::EC2::RouteTable"
        Properties = {
          VpcId = { Ref = "Vpc" }
          Tags  = [{ Key = "Name", Value = { "Fn::Sub" = "$${ProjectName}-$${SpokeName}-private-rt" } }]
        }
      }

      # 0.0.0.0/0 -> TGW. DependsOn la BAT BUOC: route tro vao
      # attachment chua ton tai se bi tu choi.
      DefaultToTgw = {
        Type      = "AWS::EC2::Route"
        DependsOn = "Attachment"
        Properties = {
          RouteTableId         = { Ref = "PrivateRt" }
          DestinationCidrBlock = "0.0.0.0/0"
          TransitGatewayId     = { Ref = "TransitGatewayId" }
        }
      }

      AssocA = {
        Type       = "AWS::EC2::SubnetRouteTableAssociation"
        Properties = { SubnetId = { Ref = "PrivateA" }, RouteTableId = { Ref = "PrivateRt" } }
      }
      AssocB = {
        Type       = "AWS::EC2::SubnetRouteTableAssociation"
        Properties = { SubnetId = { Ref = "PrivateB" }, RouteTableId = { Ref = "PrivateRt" } }
      }

      # DNS TAP TRUNG - mat xich chay o PHIA ACCOUNT SPOKE.
      #
      # Gan Route 53 Profile vao VPC la viec CHU SO HUU VPC lam, giong
      # het chuyen chap nhan loi moi RAM. Terraform o day chi co mot
      # provider tro vao lz-network nen khong lam ho duoc - nhung
      # CloudFormation thi DANG CHAY trong account spoke, nen no lam
      # duoc.
      #
      # Nho vay account spoke nhan duoc CA HAI thu cua DNS tap trung
      # ma khong ai phai dang nhap vao do:
      #   - PHZ noi bo   -> goi app khac bang ten
      #   - PHZ endpoint -> ten AWS tro vao interface endpoint dat o
      #                     security VPC, thay vi di vong ra Internet
      #
      # Bo qua khi DnsProfileId rong: profile chi ton tai khi
      # enable_dns_profile = true.
      DnsProfile = {
        Type      = "AWS::Route53Profiles::ProfileAssociation"
        Condition = "HasDnsProfile"
        Properties = {
          Name       = { "Fn::Sub" = "$${ProjectName}-$${SpokeName}" }
          ProfileId  = { Ref = "DnsProfileId" }
          ResourceId = { Ref = "Vpc" }
        }
      }

      ########################################
      # EC2 KIEM CHUNG - tuy chon
      #
      # Khong co no thi khong co gi trong VPC nay de goi toi, va moi
      # phep do east-west cross-account phai tin vao route table thay
      # vi tin vao goi tin.
      #
      # Vao bang SSM Session Manager: khong IP public, khong key pair.
      # Duong SSM di qua interface endpoint dat o security VPC (nho
      # DnsProfile o tren phan giai ten AWS ve IP noi bo), tuc no cung
      # di qua firewall - xem canh bao ve che do drop o firewall.tf.
      ########################################

      TestRole = {
        Type      = "AWS::IAM::Role"
        Condition = "HasTestInstance"
        Properties = {
          AssumeRolePolicyDocument = {
            Version = "2012-10-17"
            Statement = [{
              Effect    = "Allow"
              Principal = { Service = "ec2.amazonaws.com" }
              Action    = "sts:AssumeRole"
            }]
          }
          ManagedPolicyArns = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
        }
      }

      TestProfile = {
        Type      = "AWS::IAM::InstanceProfile"
        Condition = "HasTestInstance"
        Properties = {
          Roles = [{ Ref = "TestRole" }]
        }
      }

      # LOP THU BA cua kiem soat, ngoai route va firewall rule.
      #
      # Port 22 mo o day MA KHONG co rule firewall - do la phep thu:
      # SG cho phep, firewall van chan. Neu port 22 thong thi hoac
      # firewall dang o che do alert, hoac co rule nao khong nen co.
      TestSg = {
        Type      = "AWS::EC2::SecurityGroup"
        Condition = "HasTestInstance"
        Properties = {
          GroupDescription = { "Fn::Sub" = "EC2 test trong $${SpokeName}" }
          VpcId            = { Ref = "Vpc" }
          SecurityGroupIngress = [
            { IpProtocol = "tcp", FromPort = 80, ToPort = 80, CidrIp = { Ref = "InternalSupernet" }, Description = "HTTP tu spoke khac va tu NLB" },
            { IpProtocol = "tcp", FromPort = 22, ToPort = 22, CidrIp = { Ref = "InternalSupernet" }, Description = "SSH - mo o SG, firewall se chan" },
            { IpProtocol = "icmp", FromPort = -1, ToPort = -1, CidrIp = { Ref = "InternalSupernet" }, Description = "ICMP de troubleshoot" },
          ]
          SecurityGroupEgress = [
            { IpProtocol = "-1", CidrIp = "0.0.0.0/0", Description = "ra ngoai qua TGW" },
          ]
          Tags = [{ Key = "Name", Value = { "Fn::Sub" = "$${ProjectName}-$${SpokeName}-ec2" } }]
        }
      }

      TestInstance = {
        Type      = "AWS::EC2::Instance"
        Condition = "HasTestInstance"
        DependsOn = "DefaultToTgw"
        Properties = {
          # AMI phan giai TRONG ACCOUNT DICH luc tao stack, khong truyen
          # AMI id tu account hub sang - AMI id khac nhau theo region va
          # doi moi lan Amazon phat hanh ban moi.
          ImageId            = "{{resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}}"
          InstanceType       = { Ref = "TestInstanceType" }
          SubnetId           = { Ref = "PrivateA" }
          SecurityGroupIds   = [{ "Fn::GetAtt" = ["TestSg", "GroupId"] }]
          IamInstanceProfile = { Ref = "TestProfile" }

          # IP CO DINH, KHONG de AWS cap ngau nhien.
          #
          # Terraform khong doc duoc output cua stack instance, va
          # verify.sh khong co credential o account nay. IP tinh truoc
          # duoc la cach duy nhat kiem chung cross-account ma khong
          # phai dang nhap vao tung account.
          #
          # TINH O PHIA TERRAFORM, truyen vao day.
          #
          # Ban dau cho nay tu tinh bang Fn::Cidr long nhau. Sai:
          # Fn::Cidr tra ve KHOI CIDR ("10.20.0.0/28"), khong phai mot
          # dia chi - PrivateIpAddress can mot IP. Va CloudFormation
          # khong co phep tinh nao tren IP.
          #
          # Truyen tu Terraform con dung hon o mot diem nua: cong thuc
          # chi ton tai o MOT cho. Hai ben tu tinh roi lech nhau la
          # kieu loi khong ai phat hien cho toi khi mot phep kiem
          # curl vao dia chi khong co ai o do.
          PrivateIpAddress = { Ref = "TestPrivateIp" }

          MetadataOptions = { HttpTokens = "required" }

          # KHONG CAI GOI GI LUC BOOT - loi 63.
          #
          # Ban dau day la `dnf install -y nginx`, va no thua mot cuoc
          # dua ma khong ai thiet ke:
          #
          #   pha 3  StackSet tao VPC + attachment + EC2 -> EC2 boot NGAY
          #   pha 4  moi noi attachment vao route table
          #
          # Giua hai pha, spoke KHONG co duong ra Internet. cloud-init
          # chay `dnf install` vao dung khoang do va that bai im lang.
          # Instance van `running`, SSH van bat, chi port 80 khong ai
          # nghe - va trieu chung doc y het "mang khong thong".
          #
          # Do duoc: 3/4 spoke hong, cai duy nhat chay la stack instance
          # CUOI CUNG - no boot vua luc pha 4 xong. Mot cuoc dua thi thang
          # thua doi moi lan dung.
          #
          # python3 co san trong AL2023, khong can mang. Dung no lam web
          # server thi phep do khong con phu thuoc vao thu tu cac pha.
          UserData = {
            "Fn::Base64" = { "Fn::Sub" = join("\n", [
              "#!/bin/bash",
              "mkdir -p /var/www",
              "echo \"<h1>$${SpokeName}</h1><p>account $${AWS::AccountId} / vpc $${VpcCidr}</p>\" > /var/www/index.html",
              "cat > /etc/systemd/system/testweb.service <<'UNIT'",
              "[Unit]",
              "Description=EC2 kiem chung - web server khong can cai goi",
              "After=network-online.target",
              "[Service]",
              "WorkingDirectory=/var/www",
              "ExecStart=/usr/bin/python3 -m http.server 80 --bind 0.0.0.0",
              "Restart=always",
              "[Install]",
              "WantedBy=multi-user.target",
              "UNIT",
              "systemctl daemon-reload",
              "systemctl enable --now testweb",
              # Tien ich de troubleshoot - CO CUNG TOT, KHONG CO CUNG KHONG SAO.
              # `|| true` de mot lan dnf that bai khong lam hong ca UserData.
              "dnf install -y nmap-ncat bind-utils || true",
            ]) }
          }

          Tags = [{ Key = "Name", Value = { "Fn::Sub" = "$${ProjectName}-$${SpokeName}" } }]
        }
      }
    }

    Outputs = {
      VpcId        = { Value = { Ref = "Vpc" } }
      AttachmentId = { Value = { Ref = "Attachment" } }
    }
  })

  lifecycle {
    ignore_changes = [administration_role_arn]
  }
}

# Mot instance moi account, de CIDR khac nhau qua parameter_overrides.
resource "aws_cloudformation_stack_set_instance" "spoke" {
  # KHONG dung local.remote_spokes truc tiep - loi 59.
  #
  # Spoke khai manual_vpc = true bi loai o day: VPC cua no duoc dung
  # NGOAI StackSet. Nhung no VAN nam trong remote_spokes, nen RAM
  # principal va phan noi route table o muc 4 van tinh no - hai viec
  # do khong phu thuoc StackSet.
  for_each = local.stackset_spokes

  stack_set_name = aws_cloudformation_stack_set.spoke[0].name
  region         = var.region

  # Phai khop call_as cua stack set. Lech nhau thi CloudFormation bao
  # khong tim thay stack set - mot cau khong nhac gi toi uy quyen.
  call_as = "DELEGATED_ADMIN"

  # SERVICE_MANAGED BAT BUOC CO organizational_unit_ids - loi 52.
  #
  # Chi khai accounts thi CreateStackInstances bao:
  #   ValidationError: OrganizationalUnitIds are required
  #
  # Ly do: StackSet service-managed trien khai theo CAY TO CHUC, khong
  # theo danh sach account roi. accounts chi la BO LOC ben trong OU do,
  # va phai di kem account_filter_type.
  #
  # INTERSECTION = dung nhung account duoc liet ke, VA phai nam trong
  # OU da khai. Thieu account_filter_type thi accounts bi bo qua va
  # StackSet trien khai ra CA OU - moi account trong do deu nhan mot
  # VPC voi CUNG mot CIDR.
  # MANAGEMENT ACCOUNT CO THE KHONG NHAN DUOC STACK NAO.
  #
  # SERVICE_MANAGED trien khai theo CAY TO CHUC, va AWS loai management
  # account ra khoi cac dot trien khai do. Management lai nam truc tiep
  # duoi root, khong thuoc OU nao - nen ou_id cua no la chinh root id.
  #
  # Ket qua co the la: stack instance bao thanh cong ma khong tao gi,
  # hoac loi ngay. Ca hai deu KHONG hien ra o day - thu bat duoc no la
  # check "remote_attachments_wired" o cuoi file: khai N spoke, noi
  # duoc M, va M < N.
  #
  # Muon co VPC trong management that su thi dung stack THUONG, chay
  # tai cho bang credential cua account do:
  #   aws cloudformation create-stack --stack-name <project>-spoke-vpc \
  #     --template-body file://template.json --parameters ...
  #
  # Va can nho vi sao viec nay dang le khong nen lam: doc 22 loi 51.
  deployment_targets {
    organizational_unit_ids = [each.value.ou_id]
    accounts                = [each.value.account_id]
    account_filter_type     = "INTERSECTION"
  }

  parameter_overrides = {
    VpcCidr   = each.value.cidr
    SpokeName = each.key

    # Rong = khong tao EC2 (Condition HasTestInstance sai).
    TestPrivateIp = try(local.remote_test_ips[each.key], "")
  }

  operation_preferences {
    failure_tolerance_count = 0
    max_concurrent_count    = 1
  }

  # PHAI KHAI TUONG MINH.
  #
  # Stack chay o account spoke va tham chieu hai thu duoc share qua
  # RAM: Transit Gateway va Route 53 Profile. Terraform chi thay phu
  # thuoc vao ID cua chung - no KHONG thay phu thuoc vao viec chung da
  # duoc share hay chua, vi share la resource khac.
  #
  # Thieu dong nay thi thu tu tao la ngau nhien, va khi CloudFormation
  # chay truoc RAM thi loi bao ra o account spoke:
  #   "Transit Gateway tgw-xxx was deleted or does not exist"
  #   hoac profile khong tim thay
  # - hai cau khong nhac gi toi RAM, va se dan nguoi doc di sai huong.
  depends_on = [
    aws_ram_resource_association.tgw,
    aws_ram_principal_association.spoke_accounts,
    aws_ram_resource_association.dns_profile,
  ]
}

########################################
# 3. Tim lai attachment de noi vao route table
#
# Association va propagation CHI CHU SO HUU TGW lam duoc - nen buoc
# nay bat buoc o day, khong the de account workload tu lam.
#
# Data source doc duoc o thi diem PLAN vi attachment da ton tai truoc
# do (StackSet apply o lan truoc). Account moi thi can HAI lan apply:
# lan dau tao StackSet instance, lan sau noi route. Do la gioi han
# that, giong het aws_guardduty_member o loi 41 - chinh sach lo tuong
# lai, mot lan apply lo hien tai.
########################################

# KHONG DOI CHIEU THEO TAG - loi 57.
#
# Ban dau khoi nay lay het attachment cua TGW roi tim cai co tag
# Name = "<project>-tgwa-<spoke>", tag ma template CloudFormation dat
# o account dich. Do duoc:
#
#   attachment cua 761558631239  ->  "tags": []
#   attachment cua 436908791055  ->  du 8 tag
#
# TAG TREN RESOURCE CHIA SE THUOC VE ACCOUNT DA TAO CHUNG. Chu so huu
# TGW nhin thay attachment nhung KHONG nhin thay tag do account spoke
# dat. Nen phep doi chieu do khong phai "cham mot nhip apply" - no
# khong bao gio khop, va loi cua check con day nguoi doc di apply lai
# mai mai.
#
# ResourceOwnerId thi LUON nhin thay, va Terraform da biet account_id
# tu var.spokes - khong can nhin sang account kia.
#
# Loc MOT data source moi ACCOUNT, khong phai moi spoke: hai spoke
# cung nam trong mot account thi ca hai attachment deu phai duoc noi,
# va khoa theo ten spoke se ghep nham mot cai vao ca hai.
data "aws_ec2_transit_gateway_attachments" "remote_by_account" {
  for_each = local.wire ? toset(distinct([for v in local.remote_spokes : v.account_id])) : toset([])

  filter {
    name   = "transit-gateway-id"
    values = [aws_ec2_transit_gateway.hub.id]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  filter {
    name   = "resource-type"
    values = ["vpc"]
  }
  filter {
    name   = "resource-owner-id"
    values = [each.value]
  }
}

locals {
  # Khoa la CHINH attachment id, khong phai ten spoke. Nho vay so spoke
  # trong mot account khong con quan trong: moi attachment tim thay deu
  # duoc noi dung mot lan.
  remote_attachments_ready = local.wire ? toset(flatten([
    for d in data.aws_ec2_transit_gateway_attachments.remote_by_account : d.ids
  ])) : toset([])
}

########################################
# 4. Noi vao route table - dung khuon voi spoke noi bo
########################################

resource "aws_ec2_transit_gateway_route_table_association" "remote_spokes" {
  for_each = local.remote_attachments_ready

  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

# Firewall BAT: spoke propagate vao rtb-security de goi tra ve tim
# duoc duong sau khi qua thanh tra.
resource "aws_ec2_transit_gateway_route_table_propagation" "remote_to_security" {
  for_each = var.enable_firewall ? local.remote_attachments_ready : toset([])

  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security[0].id
}

# Firewall TAT: propagate thang vao rtb-egress.
resource "aws_ec2_transit_gateway_route_table_propagation" "remote_to_egress" {
  for_each = var.enable_firewall ? toset([]) : local.remote_attachments_ready

  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

########################################
# KIEM TRA CHEO
########################################

# RAM chia se voi Organizations phai duoc BAT o cap to chuc truoc.
# Chua bat thi lenh share bao hai cau khac nhau ma cung mot goc:
#   "can only be shared within your AWS Organization"
#   "Organization o-xxxx could not be found"
# Cau thu hai de doc nham thanh sai ARN.
#
# Bat roi ma VAN hong la loi 56 - luc do ram_use_external_principals la
# duong vong duy nhat dang biet.
check "ram_sharing_with_organization_enabled" {
  assert {
    condition = !local.has_remote || var.ram_sharing_with_organization_enabled
    error_message = join(" ", [
      "Co spoke o account khac nhung chua xac nhan da bat RAM sharing",
      "voi Organizations. Chay MOT LAN tu MANAGEMENT account:",
      "aws ram enable-sharing-with-aws-organization",
      "Kiem: aws ram get-resource-shares --resource-owner SELF",
      "(khong bat thi moi lenh share deu bao 'Organization could not be",
      "found' - nghe nhu sai ARN, thuc ra la thieu buoc nay).",
    ])
  }
}

# TGW phai den duoc spoke account bang MOT trong hai duong:
#   ram_use_external_principals = true  Terraform tu tao share
#   tgw_shared_manually         = true  da share bang CLI
# Khong duong nao thi StackSet o muc 2 bao "Transit Gateway ... was
# deleted or does not exist" - mot cau khong nhac gi toi RAM.
check "tgw_shared_with_spoke_accounts" {
  assert {
    condition = (
      !local.has_remote
      || var.ram_use_external_principals
      || var.tgw_shared_manually
    )
    error_message = join(" ", [
      "Co spoke o account khac nhung TGW chua den duoc account do.",
      "Chon MOT: dat ram_use_external_principals = true de Terraform tu",
      "tao share (doc ba he qua o muc 1 truoc - no NOI RAO CHAN va van",
      "can accept invitation o moi spoke account), hoac share bang CLI",
      "roi dat tgw_shared_manually = true.",
      "Chua share thi StackSet bao 'Transit Gateway ... was deleted or",
      "does not exist', mot cau khong nhac gi toi RAM.",
    ])
  }
}

# Share ngoai to chuc KHONG tu dong duoc chap nhan.
#
# Day la cho im lang nhat cua ca duong nay: Terraform apply XANH, share
# ACTIVE, principal ASSOCIATING - va spoke account van khong thay TGW
# cho toi khi co nguoi bam nhan. Khong loi, khong canh bao.
check "remote_accounts_accepted_invitation" {
  assert {
    condition = (
      !local.has_remote
      || !var.ram_use_external_principals
      || var.ram_invitations_accepted
    )
    error_message = join(" ", [
      "ram_use_external_principals = true nhung chua xac nhan cac spoke",
      "account da chap nhan loi moi. Terraform khong lam ho duoc - demo",
      "chi co MOT provider. Chay o TUNG spoke account:",
      "aws ram get-resource-share-invitations --region <region>",
      "aws ram accept-resource-share-invitation",
      "--resource-share-invitation-arn <arn>",
      "Kiem tu spoke account: aws ec2 describe-transit-gateways",
      "(rong = chua nhan).",
    ])
  }
}

# Khai account vao share_tgw_with_accounts ma quen bat co thi khong
# resource nao duoc tao va cung khong loi gi - dung kieu im lang da
# gay ra loi 49 va 57.
check "share_list_has_effect" {
  assert {
    condition     = length(var.share_tgw_with_accounts) == 0 || var.ram_use_external_principals
    error_message = "share_tgw_with_accounts co account nhung ram_use_external_principals = false, nen khong share nao duoc tao. Bat bien do, hoac bo danh sach di cho khoi hieu nham la da share."
  }
}

check "network_account_is_stackset_delegated_admin" {
  assert {
    condition = !local.has_remote || var.network_account_is_stackset_delegated_admin
    error_message = join(" ", [
      "Co spoke o account khac nhung account nay chua duoc dang ky lam",
      "delegated administrator cua CloudFormation StackSets.",
      "CreateStackSet se bao AccessDenied - va loi do KHONG nhac gi toi",
      "uy quyen.",
      "Chay MOT LAN tu MANAGEMENT account:",
      "aws organizations register-delegated-administrator",
      "--service-principal member.org.stacksets.cloudformation.amazonaws.com",
      "--account-id <network-account-id>",
      "DUNG chay ca bo code nay tu management account de vuot qua:",
      "demo chi co mot provider, nen toan bo hub se duoc tao trong",
      "management account - noi SCP khong bao gio ap duoc. Xem loi 51.",
    ])
  }
}

check "remote_attachments_wired" {
  assert {
    condition = !local.wire || length(local.remote_attachments_ready) == length(local.remote_spokes)
    error_message = join(" ", [
      "Da khai", tostring(length(local.remote_spokes)), "spoke o account khac",
      "nhung chi noi duoc", tostring(length(local.remote_attachments_ready)),
      "vao route table.",
      "Attachment TON TAI ma khong thuoc route table nao thi State van la",
      "'available', khong loi, khong canh bao, va KHONG MOT GOI TIN NAO",
      "di qua.",
      "Thuong chi la thu tu: StackSet vua tao attachment o chinh lan apply",
      "nay nen data source chua thay. CHAY LAI terraform apply mot lan nua.",
      "Van thieu sau lan hai thi doi chieu ResourceOwnerId - KHONG phai tag,",
      "tag cua account spoke khong nhin thay duoc tu day (loi 57):",
      "aws ec2 describe-transit-gateway-attachments",
      "--filters Name=transit-gateway-id,Values=<tgw-id>",
      "Name=resource-type,Values=vpc Name=state,Values=available",
      "--query 'TransitGatewayAttachments[].[TransitGatewayAttachmentId,ResourceOwnerId]'",
      "Account nao co trong var.spokes ma khong hien o day thi StackSet",
      "chua tao xong attachment o account do.",
    ])
  }
}

########################################
# HAI PHA - VI SAO KHONG GOP LAM MOT
#
# LOI 50. Ban dau file nay tim attachment bang data source ngay trong
# cung mot lan apply. Plan chet:
#
#   Error: Invalid for_each argument
#   The "for_each" set includes values derived from resource attributes
#   that cannot be determined until apply
#
# Data source loc theo aws_ec2_transit_gateway.hub.id, ma TGW duoc TAO
# TRONG CHINH CONFIG NAY. Lan apply dau, hub.id chua biet -> danh sach
# attachment chua biet -> Terraform khong dung duoc bo khoa for_each.
#
# Khong lach duoc bang try() hay coalesce(): chua biet la chua biet.
#
# Va day dung la dieu ma landing-zone/network/variables.tf da canh bao
# tu truoc, o mo ta bien spoke_attachments. Toi cho rang no chi dung
# mot phan - no dung han trong dung cau hinh nay.
#
# ---------------------------------------------------------------
# CACH DUNG
#
#   Pha 1   wire_remote_attachments = false   (mac dinh)
#           -> tao TGW, share RAM, StackSet, VPC + attachment o
#              account dich. Route CHUA noi.
#
#   Pha 2   wire_remote_attachments = true
#           -> TGW da nam trong state nen hub.id biet o thi diem plan,
#              data source doc duoc ID that, for_each dung duoc.
#              Route duoc noi.
#
# Giua hai pha, attachment TON TAI ma khong thuoc route table nao:
# State la 'available', khong loi, va khong mot goi tin nao di qua.
# Dung dung o day.
########################################
