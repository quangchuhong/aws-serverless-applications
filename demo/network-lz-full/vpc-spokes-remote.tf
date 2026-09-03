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
  ram_share = local.has_remote && var.ram_use_external_principals ? 1 : 0
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

# Mot principal moi spoke account - KHONG share cho ca to chuc.
#
# Dung distinct(): hai spoke cung nam trong mot account la chuyen binh
# thuong (vi du app-prod va app-uat), va associate cung mot principal
# hai lan thi RAM tra ve loi trung.
resource "aws_ram_principal_association" "spoke_accounts" {
  for_each = toset(
    local.ram_share == 0 ? [] : distinct([for v in local.remote_spokes : v.account_id])
  )

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
  capabilities     = []

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
  for_each = local.remote_spokes

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
  deployment_targets {
    organizational_unit_ids = [each.value.ou_id]
    accounts                = [each.value.account_id]
    account_filter_type     = "INTERSECTION"
  }

  parameter_overrides = {
    VpcCidr   = each.value.cidr
    SpokeName = each.key
  }

  operation_preferences {
    failure_tolerance_count = 0
    max_concurrent_count    = 1
  }
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

data "aws_ec2_transit_gateway_attachments" "remote_spokes" {
  count = local.wire ? 1 : 0

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
}

data "aws_ec2_transit_gateway_attachment" "remote_spoke" {
  for_each = local.wire ? toset(one(data.aws_ec2_transit_gateway_attachments.remote_spokes[*].ids)) : []

  transit_gateway_attachment_id = each.value
}

locals {
  # Loc lay attachment cua account KHAC, doi chieu theo tag Name ma
  # template da dat: <project>-tgwa-<spoke>.
  #
  # Doi chieu theo TAG chu khong theo thu tu: danh sach tra ve khong
  # co thu tu bao dam, va lay theo chi so la kieu loi da gap o loi 39.
  remote_attachment_ids = local.wire == false ? {} : {
    for k, v in local.remote_spokes : k => one([
      for a in data.aws_ec2_transit_gateway_attachment.remote_spoke :
      a.id if try(a.tags["Name"], "") == "${var.project}-tgwa-${k}"
    ])
  }

  # Attachment chua tim thay = StackSet vua chay xong o CHINH lan apply
  # nay, data source doc truoc do nen chua thay. Apply lan hai la co.
  remote_attachments_ready = {
    for k, v in local.remote_attachment_ids : k => v if v != null
  }
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
  for_each = var.enable_firewall ? local.remote_attachments_ready : {}

  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security[0].id
}

# Firewall TAT: propagate thang vao rtb-egress.
resource "aws_ec2_transit_gateway_route_table_propagation" "remote_to_egress" {
  for_each = var.enable_firewall ? {} : local.remote_attachments_ready

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
      "Van thieu sau lan hai thi doi chieu tag Name:",
      "aws ec2 describe-transit-gateway-attachments",
      "--filters Name=transit-gateway-id,Values=<tgw-id>",
      "--query 'TransitGatewayAttachments[].[TransitGatewayAttachmentId,Tags]'",
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
