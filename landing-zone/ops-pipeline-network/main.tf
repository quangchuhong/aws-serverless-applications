########################################
# DNS, ENDPOINT, TUONG LUA - HAI STAGE, HAI MUC RUI RO
#
# =======================================================================
# VI SAO TACH LAM HAI STAGE TRONG CUNG MOT LAYER
#
# network/ops chua ca hai loai thay doi, va chung khac han nhau o mot
# diem: thay doi sai co trieu chung hay khong.
#
#   DNS record sai      co trieu chung NGAY. Co nguoi goi.
#   ingress rule moi    KHONG co trieu chung. Mot cua vua mo ra, va
#                       khong co gi bao rang no da mo.
#   rule group bi go    luu luong truoc day bi chan gio di qua, va
#                       khong co log nao noi mot luat vua bien mat.
#
# Gop chung lam mot stage thi hoac moi thay doi DNS phai cho nguoi duyet
# (ma sat, va roi cong duyet bi bam theo phan xa), hoac khong cai nao
# duoc duyet (va mot ingress rule moi di thang ra AWS).
#
# Tach bang -target, dung khuon da dung cho sec-ou / sec-scp / sec-tagging.
# Chi cloudops-firewall nam trong approve_stages.
########################################

locals {
  stages = [
    {
      key     = "cloudops-network"
      layer   = "landing-zone/network/ops"
      enabled = var.enable_network_stage

      targets = [
        "aws_route53_record.ops",
        "aws_route53_record.ops_endpoint_apex",
        "aws_route53_record.ops_endpoint_wildcard",
        "aws_route53_zone.ops_endpoint",
        "aws_route53profiles_resource_association.ops_endpoint",
        "aws_vpc_endpoint.ops",
        "aws_ec2_transit_gateway_route.ops",
        "aws_lb_target_group.partner_service",
        "aws_lb_target_group_attachment.partner_service",
        "aws_lb_listener.partner_service",
        "aws_vpn_connection_route.partner_extra",
        "aws_cloudwatch_metric_alarm.partner_vpn_down",
        "aws_cloudwatch_metric_alarm.partner_vpn_degraded",
      ]

      khong_co_lint = "network/ops khong co catalog - phep kiem y nghia la gate.py; xoa mot alarm hay mot rule group la NOI"

      mo_ta = "DNS record, endpoint, route, load balancer, alarm. Khong co cong duyet - thay doi sai o day co trieu chung ngay."
    },

    ####################################
    # TUONG LUA - CO CONG DUYET
    #
    # Hai resource, va ca hai deu la "mot cua". gate.py coi TAO mot
    # ingress rule la NOI (chieu nguoc voi truc giac ve `tao`), va coi
    # XOA mot rule group la NOI.
    ####################################
    {
      key     = "cloudops-firewall"
      layer   = "landing-zone/network/ops"
      enabled = var.enable_firewall_stage

      targets = [
        "aws_networkfirewall_rule_group.ops_east_west",
        "aws_vpc_security_group_ingress_rule.partner_service",
      ]

      khong_co_lint = "luat tuong lua khai trong HCL, chua co catalog - phep kiem y nghia la gate.py, muc aws_networkfirewall_rule_group va aws_vpc_security_group_ingress_rule"

      mo_ta = "Nhom luat tuong lua va ingress rule. TAO mot ingress rule la MO MOT CUA - doc ky cidr_ipv4 va khoang port."
    },
  ]

  catalogs = []

  khong_co_catalog = "network/ops khai luat trong HCL (firewall.tf, vpn.tf), chua co catalog YAML. Khi catalog hoa thi them vao local.catalogs va XOA dong nay."

  ####################################
  # QUYEN: CHU YEU LA sts:AssumeRole
  #
  # network/ops tao resource o ACCOUNT NETWORK. Hom nay no lam viec do
  # bang `profile` - xem versions.tf muc 2 - nen phan duoi day CHUA dung
  # duoc. Khi layer co duong assume_role thi role dich mang quyen that,
  # con role nay chi can assume duoc sang no.
  #
  # Phan doc rong o day danh cho nhung gi layer doc TU ACCOUNT
  # MANAGEMENT: terraform_remote_state cua layer cha nam trong bucket
  # state, va module da cap quyen doc bucket do.
  ####################################
  ####################################
  # STATE LAYER NAY DOC CUA LAYER KHAC
  #
  # network/ops doc state cua layer CHA (landing-zone/network) qua
  # terraform_remote_state de lay TGW, VPC va vung. Xem
  # network/ops/main.tf muc "DUONG DAN STATE CUA LAYER CHA".
  #
  # KHOA KHONG KHOP DUONG DAN - giong layer_keys, va vi cung mot ly do:
  # layer network truoc o demo/network-lz-full va khoa state giu nguyen
  # khi duong dan doi.
  #
  # CHI DOC: module cap dung s3:GetObject.
  ####################################
  state_chi_doc = [
    "demo-network-lz-full/terraform.tfstate",
  ]

  quyen_dich_vu = [
    {
      Sid      = "AssumeVaoAccountNetwork"
      Effect   = "Allow"
      Action   = ["sts:AssumeRole"]
      Resource = var.network_pipeline_role_arns
    },
  ]

  tu_choi_dich_vu = [
    {
      Sid    = "KhongChamTgwHayVpc"
      Effect = "Deny"
      Action = [
        # Ha tang nen cua mang - TGW, VPC, attachment, VPN - thuoc layer
        # CHA (landing-zone/network), khong thuoc ops. Mot lenh o day co
        # the lam mat duong cua ca to chuc, va no khong hoan tac bang
        # mot lan apply.
        "ec2:DeleteTransitGateway",
        "ec2:DeleteTransitGatewayVpcAttachment",
        "ec2:DeleteVpc",
        "ec2:DeleteSubnet",
        "ec2:DeleteVpnConnection",
        "ec2:DeleteVpnGateway",
        "ec2:DeleteCustomerGateway",
        "ec2:DeleteNatGateway",
        "network-firewall:DeleteFirewall",
        "network-firewall:DeleteFirewallPolicy",
      ]
      Resource = "*"
    },
  ]
}

module "pipeline" {
  source = "../../modules/tf-pipeline"

  ten     = "ops-network"
  enable  = var.enable
  project = var.project
  region  = var.region

  stages           = local.stages
  catalogs         = local.catalogs
  khong_co_catalog = local.khong_co_catalog
  state_chi_doc    = local.state_chi_doc
  quyen_dich_vu    = local.quyen_dich_vu
  tu_choi_dich_vu  = local.tu_choi_dich_vu

  source_type       = var.source_type
  repository_name   = var.repository_name
  branch_name       = var.branch_name
  tu_kich_hoat      = var.tu_kich_hoat
  source_bucket     = var.source_bucket
  source_object_key = var.source_object_key

  state_bucket     = var.state_bucket
  state_lock_table = var.state_lock_table
  layer_keys       = var.layer_keys
  tfvars_bucket    = var.tfvars_bucket

  approve_stages  = var.approve_stages
  approval_emails = var.approval_emails

  drift_cron      = var.drift_cron
  drift_emails    = var.drift_emails
  drift_topic_arn = var.drift_topic_arn

  expiry_blocks_pipeline = var.expiry_blocks_pipeline
  build_timeout_minutes  = var.build_timeout_minutes
  log_retention_days     = var.log_retention_days
}
