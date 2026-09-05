########################################
# MANG NEN CHO ACCOUNT WORKLOAD
#
# Account nao co khoi `network` trong catalog thi nhan mot VPC dung
# theo thiet ke: 4 subnet, TGW attachment, DNS tap trung, gateway
# endpoint. Account khong co khoi do thi khong nhan gi - account ha
# tang khong can VPC.
#
# ---------------------------------------------------------------
# MOT STACK INSTANCE MOI ACCOUNT, KHONG PHAI MOT CHO CA OU
#
# Khac han StackSet cua vpc-sweep. Cai kia lam CUNG MOT viec cho moi
# account nen deploy thang xuong OU. Cai nay thi moi account mot CIDR
# khac nhau, tuc moi account mot bo tham so - va tham so chi de len
# duoc theo tung instance.
#
# ---------------------------------------------------------------
# THU TU, VA MOT VIEC KHONG TU DONG DUOC
#
#   1. account tao xong          <- aws_organizations_account
#   2. stack instance tao VPC + attachment
#   3. attachment hien ra o ACCOUNT NETWORK o trang thai available
#   4. attachment duoc noi vao rtb-spokes  <- VIEC NAY O LAYER KHAC
#
# Buoc 4 nam o `landing-zone/network`, vi attachment xuat hien trong
# account so huu TGW chu khong phai account workload. Layer nay
# khong voi toi do duoc.
#
# Output `paste_spokes` sinh san khoi tfvars cho buoc do, kem
# manual_vpc = true - xem mo ta cua no.
# Bo qua buoc 4 thi VPC ton tai, attachment ton tai, va KHONG CO GOI
# TIN NAO DI DAU CA - attachment khong nam trong route table nao thi
# no khong hoc duoc duong nao va khong ai hoc duoc duong toi no.
########################################

locals {
  # Account co yeu cau mang. Khoa trung voi khoa cua account.
  #
  # DNS TAP TRUNG DI THEO TGW, KHONG DOC LAP.
  #
  # attach_dns mac dinh bang attach_tgw chu khong phai true. Ly do la
  # ky thuat, khong phai so thich: Route 53 Profile mang PHZ tro ten
  # dich vu AWS vao INTERFACE ENDPOINT dat o security VPC, dai
  # 10.1.0.0/16. Mot VPC khong noi TGW khong co duong nao toi dai do.
  #
  # Nen gan profile cho mot VPC khong attach nghia la moi loi goi API
  # cua AWS trong do phan giai ra mot dia chi KHONG DI TOI DUOC - te
  # hon han IP cong khai, vi it ra IP cong khai con di duoc. Trieu
  # chung la "account moi hong hoan toan", va cho dau tien nguoi ta
  # tim la endpoint, noi khong co gi sai.
  #
  # lint.sh da noi dieu nay voi nguoi dung tu truoc ("attach_tgw =
  # false - khong co DNS tap trung"), con code thi van gan profile.
  # Day la cho sua cho khop lai.
  #
  # Van de len duoc bang attach_dns cho truong hop hiem: VPC khong
  # attach nhung duoc noi bang cach khac (peering chang han).
  spoke_requests = {
    for a in local.catalog_raw : a.name => {
      vpc_cidr   = a.network.vpc_cidr
      attach_tgw = try(a.network.attach_tgw, true)
      attach_dns = try(a.network.attach_dns, try(a.network.attach_tgw, true))
      ou         = a.ou
    }
    if try(a.network, null) != null
  }

  # Bat ca nhanh nay bang mot dieu kien duy nhat, giong local.enabled.
  spokes_on = local.enabled && length(local.spoke_requests) > 0

  # Handle tu layer network. Rong = chua ai dan vao.
  net = var.network_handles

  # Account xin noi TGW nhung chua co TGW de noi.
  #
  # DAY LA PRECONDITION, KHONG PHAI check - va no da tung la check.
  #
  # Ly do cu ghi o day la "khong chan apply: VPC van dung duoc, chi la
  # chua noi vao luoi". Cau do SAI. Template nay co y khong tao IGW va
  # khong tao NAT, vi duong ra Internet di qua egress VPC tap trung.
  # Bo not TGW ra thi VPC con lai KHONG CO DUONG NAO DI DAU CA: khong
  # ra Internet, khong sang spoke khac, khong toi interface endpoint.
  # No khong "dung duoc"; no la mot cai vo.
  #
  # Va gia phai tra khong chi la mot VPC vo dung. Stack duoc tao voi
  # AttachTgw = false, nen lan sua sau la mot CloudFormation UPDATE
  # tren stack dang chay o account khac - dat hon han viec dung lai
  # ba muoi giay de dan mot dong network_handles.
  #
  # Canh bao thi doc duoc, cuon qua duoc, va se bi cuon qua: no nam
  # giua mot man hinh plan day chu, sau mot dong "Plan: 4 to add" trong
  # nhu moi thu deu on.
  #
  # Account khai attach_tgw = false KHONG bi chan - no co y khong noi.
  spokes_without_tgw = [
    for k, v in local.spoke_requests : k
    if v.attach_tgw && try(local.net.transit_gateway_id, "") == ""
  ]

  # Chi tinh account CO XIN DNS tap trung. Account attach_dns = false
  # khong thieu gi ca - no co y khong dung.
  spokes_without_dns = [
    for k, v in local.spoke_requests : k
    if v.attach_dns && try(local.net.dns_profile_id, "") == ""
  ]
}

resource "aws_cloudformation_stack_set" "spoke_network" {
  count = local.spokes_on ? 1 : 0

  name        = "${var.project}-spoke-network"
  description = "Mang nen cho account workload: VPC, TGW attachment, DNS tap trung"

  permission_model = "SERVICE_MANAGED"

  # KHONG bat auto_deployment.
  #
  # StackSet kia bat, vi moi account trong OU deu can cung mot thu.
  # O day thi khong: mot account moi vao OU KHONG duoc tu dong nhan
  # mot VPC, boi vi khong ai biet CIDR nao danh cho no.
  #
  # Bat auto_deployment o day nghia la moi account moi deu lay cung
  # mot CIDR mac dinh - tuc trung dai voi nhau ngay tu ngay dau.
  auto_deployment {
    enabled                          = false
    retain_stacks_on_account_removal = false
  }

  template_body = file("${path.module}/templates/spoke-network.yaml")

  parameters = {
    ProjectName      = var.project
    AccountName      = "chua-dat"
    VpcCidr          = "10.255.0.0/16"
    AzA              = local.azs[0]
    AzB              = local.azs[1]
    TransitGatewayId = try(local.net.transit_gateway_id, "")
    DnsProfileId     = try(local.net.dns_profile_id, "")
    InternalSupernet = try(local.net.internal_supernet, "10.0.0.0/8")
    AttachTgw        = "false"
  }

  operation_preferences {
    failure_tolerance_percentage = 0
    max_concurrent_percentage    = 25
    region_concurrency_type      = "PARALLEL"
  }

  lifecycle {
    ignore_changes = [administration_role_arn]
  }
}

# failure_tolerance = 0 o tren, KHONG phai 10 nhu StackSet kia.
#
# Sweep default VPC hong o mot account thi cac account khac van nen
# chay tiep - viec do doc lap nhau. Mang thi khong: mot VPC tao nua
# chung, hoac mot attachment tao ma route khong tao, de lai mot trang
# thai khong ai doc duoc bang mat. Dung ngay o cai dau tien.

resource "aws_cloudformation_stack_set_instance" "spoke_network" {
  for_each = local.spokes_on ? local.spoke_requests : {}

  stack_set_name = aws_cloudformation_stack_set.spoke_network[0].name
  region         = var.region

  # INTERSECTION: trong OU nay, CHI account nay.
  #
  # StackSet service-managed trien khai theo cay to chuc, nen phai
  # khai OU. Nhung ta muon dung mot account trong do - va account
  # filter la cach duy nhat noi dieu do.
  deployment_targets {
    organizational_unit_ids = [var.ou_ids[each.value.ou]]
    accounts                = [aws_organizations_account.this[each.key].id]
    account_filter_type     = "INTERSECTION"
  }

  parameter_overrides = {
    AccountName = each.key
    VpcCidr     = each.value.vpc_cidr
    AttachTgw   = tostring(each.value.attach_tgw)

    # Rong = Condition DoDns sai = khong gan Profile.
    #
    # Phai de len o TUNG INSTANCE. Gia tri mac dinh cua stack set la
    # dns_profile_id, nen khong co dong nay thi MOI account deu duoc
    # gan profile, ke ca account khong noi TGW.
    DnsProfileId = each.value.attach_dns ? try(local.net.dns_profile_id, "") : ""
  }

  operation_preferences {
    failure_tolerance_percentage = 0
    max_concurrent_percentage    = 25
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}

########################################
# KIEM TRA CHEO
########################################

# CHAN, khong phai canh bao. Ly do day du o chu thich cua
# local.spokes_without_tgw.
resource "terraform_data" "spoke_network_guard" {
  count = local.spokes_on ? 1 : 0

  input = { thieu_tgw = local.spokes_without_tgw }

  lifecycle {
    precondition {
      condition = length(local.spokes_without_tgw) == 0
      error_message = join(" ", [
        "network_handles chua co transit_gateway_id, nhung cac account nay xin noi TGW:",
        join(", ", local.spokes_without_tgw),
        ".",
        "Template nay CO Y khong tao IGW va khong tao NAT - duong ra Internet di qua",
        "egress VPC tap trung. Thieu not TGW thi VPC dung len se KHONG CO DUONG NAO",
        "DI DAU CA, va sua sau la mot CloudFormation UPDATE tren stack o account khac.",
        "Lay handle:  cd ../network && terraform output -raw paste_network_handles",
        "Account co y khong noi TGW thi khai attach_tgw: false trong catalog.",
      ])
    }
  }
}

check "spokes_have_central_dns" {
  assert {
    condition     = length(local.spokes_without_dns) == 0
    error_message = "Chua co dns_profile_id trong network_handles: ${join(", ", local.spokes_without_dns)}. VPC se khong phan giai duoc ten noi bo, va ten dich vu AWS se tro ra IP CONG KHAI - luu luong di vong ra Internet trong khi interface endpoint tap trung van tinh tien ma khong ai dung."
  }
}
