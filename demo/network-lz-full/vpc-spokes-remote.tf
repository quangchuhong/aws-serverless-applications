########################################
# SPOKE O ACCOUNT KHAC - VPC + attachment + route, tu dong
#
# Spoke trong vpc-spokes.tf nam CUNG ACCOUNT voi TGW. File nay lo
# truong hop spoke nam o ACCOUNT KHAC trong to chuc - dung mo hinh
# that cua Landing Zone.
#
# ---------------------------------------------------------------
# PHAI CHAY TU MANAGEMENT ACCOUNT
#
# Day khong phai so thich ma la rang buoc IAM:
#
#   - OrganizationAccountAccessRole trong account workload chi tin
#     MANAGEMENT account. lz-network khong assume duoc vao do.
#   - StackSet SERVICE_MANAGED chi tao duoc tu management account
#     hoac delegated administrator cua CloudFormation.
#
# Chay bang credential cua lz-network thi remote_spokes phai de RONG,
# va check "remote_spokes_need_management_account" se nhac.
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
}

########################################
# 1. Share TGW ra to chuc
#
# Account khac KHONG THAY TGW neu khong share - va "khong thay" o day
# nghia la CreateTransitGatewayVpcAttachment bao khong tim thay
# resource, khong phai bao thieu quyen.
########################################

resource "aws_ram_resource_share" "tgw" {
  count = local.has_remote ? 1 : 0

  name                      = "${var.project}-tgw"
  allow_external_principals = false

  tags = { Name = "${var.project}-tgw-share" }
}

resource "aws_ram_resource_association" "tgw" {
  count = local.has_remote ? 1 : 0

  resource_arn       = aws_ec2_transit_gateway.hub.arn
  resource_share_arn = aws_ram_resource_share.tgw[0].arn
}

resource "aws_ram_principal_association" "org" {
  count = local.has_remote ? 1 : 0

  # Dung var.organization_arn - CUNG CACH ma dns.tf dang share DNS
  # profile. Ban dau doan la co data "aws_organizations_organization"
  # nhu ben landing-zone/network; demo KHONG khai data source do, va
  # them mot cai nua thi hai cho share cung mot to chuc lai lay ARN
  # theo hai duong khac nhau.
  principal          = var.organization_arn
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
    Description              = "Spoke VPC nối vào Transit Gateway trung tâm"

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

  deployment_targets {
    accounts = [each.value.account_id]
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
  count = local.has_remote ? 1 : 0

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

  depends_on = [aws_cloudformation_stack_set_instance.spoke]
}

data "aws_ec2_transit_gateway_attachment" "remote_spoke" {
  for_each = local.has_remote ? toset(one(data.aws_ec2_transit_gateway_attachments.remote_spokes[*].ids)) : []

  transit_gateway_attachment_id = each.value
}

locals {
  # Loc lay attachment cua account KHAC, doi chieu theo tag Name ma
  # template da dat: <project>-tgwa-<spoke>.
  #
  # Doi chieu theo TAG chu khong theo thu tu: danh sach tra ve khong
  # co thu tu bao dam, va lay theo chi so la kieu loi da gap o loi 39.
  remote_attachment_ids = {
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

check "remote_spokes_need_organization_arn" {
  assert {
    condition = !local.has_remote || var.organization_arn != ""
    error_message = join(" ", [
      "Co spoke o account khac nhung organization_arn de rong.",
      "Khong share TGW ra to chuc thi account dich KHONG THAY TGW, va",
      "CloudFormation bao khong tim thay resource - mot cau khong nhac",
      "gi toi RAM.",
      "Lay bang: aws organizations describe-organization",
      "--query Organization.Arn --output text",
    ])
  }
}

check "remote_spokes_need_management_account" {
  assert {
    condition = !local.has_remote || var.i_am_running_from_management_account
    error_message = join(" ", [
      "remote_spokes da khai nhung i_am_running_from_management_account = false.",
      "StackSet SERVICE_MANAGED chi tao duoc tu management account hoac",
      "delegated administrator cua CloudFormation, va",
      "OrganizationAccountAccessRole trong account workload chi tin",
      "management account.",
      "Chay bang credential cua lz-network se bao AccessDenied o buoc",
      "CreateStackSet - va loi do KHONG noi gi ve nguyen nhan that.",
      "Kiem: aws sts get-caller-identity --query Account",
    ])
  }
}

check "remote_attachments_wired" {
  assert {
    condition = length(local.remote_attachments_ready) == length(local.remote_spokes)
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
