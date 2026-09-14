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

      # Provider cua layer tu assume role nay. Buildspec export
      # TF_VAR_assume_role_arn; tfvars KHONG mang gia tri nay, vi tfvars
      # dung chung voi nguoi chay tay (ho dung var.aws_profile).
      assume_role_arn = var.network_deploy_role_arn

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

      assume_role_arn = var.network_deploy_role_arn

      mo_ta = "Nhom luat tuong lua va ingress rule. TAO mot ingress rule la MO MOT CUA - doc ky cidr_ipv4 va khoang port."
    },
  ]

  catalogs = []

  khong_co_catalog = "network/ops khai luat trong HCL (firewall.tf, vpn.tf), chua co catalog YAML. Khi catalog hoa thi them vao local.catalogs va XOA dong nay."

  ####################################
  # QUYEN: CHU YEU LA sts:AssumeRole
  #
  # network/ops tao resource o ACCOUNT NETWORK. Truoc day no chi lam duoc
  # viec do bang `profile`, tuc chi chay duoc bang tay. Layer GIO DA CO
  # duong assume_role (network/ops/versions.tf), nen phan duoi day dung
  # duoc.
  #
  # Role DICH mang quyen that; role nay chi can assume duoc sang no. Do
  # cung la ly do khoi Deny ben duoi khong phu duoc phan lien account -
  # xem chu thich cua no.
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

  ####################################
  # PHAM VI THAT CUA KHOI DENY NAY - DOC TRUOC KHI TIN NO
  #
  # Deny duoi day gan vao role CodeBuild o ACCOUNT MANAGEMENT. Sau
  # `sts:AssumeRole`, phien moi mang quyen cua ROLE DICH, va policy cua
  # danh tinh goi KHONG di theo.
  #
  # Nen no CHI rang buoc nhung goi API layer nay thuc hien TRUC TIEP bang
  # danh tinh cua CodeBuild, tuc trong account management. Voi nhung
  # resource nam o account khac - qua provider alias co assume_role - no
  # KHONG co tac dung.
  #
  # Va role dich hien tai la OrganizationAccountAccessRole: FULL ADMIN
  # trong account do. Day la QUYET DINH TAM THOI da duoc thong qua - cho
  # cac pipeline chay on roi thu hep sau - khong phai mot cho bo sot.
  #
  # CACH CHUA, khi den luc: `assume_role` cua provider AWS nhan mot
  # SESSION POLICY (truong `policy`). Session policy giao voi quyen cua
  # role dich, nen Deny dat o do rang buoc dung phien dang lam viec. Do
  # la cho DUY NHAT mot Deny co tac dung cho cong viec lien account.
  #
  # GIU khoi nay chu khong xoa: no van co tac dung cho phan chay trong
  # account management, va no ghi lai Y DINH - danh sach nay la ban thao
  # cua session policy tuong lai.
  ####################################
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

########################################
# ROLE PROVIDER ASSUME PHAI NAM TRONG DANH SACH DUOC PHEP
#
# network_pipeline_role_arns la thu role CodeBuild DUOC PHEP assume (mot
# statement IAM). network_deploy_role_arn la thu provider THUC SU assume.
#
# Lech nhau thi khong co loi luc apply layer nay - hai bien doc lap. Loi
# hien ra luc PIPELINE CHAY, duoi dang AccessDenied cua STS, va thong bao
# do khong nhac gi toi bien nao ca.
########################################
check "role_assume_nam_trong_danh_sach" {
  assert {
    condition = (
      var.network_deploy_role_arn == "" ||
      contains(var.network_pipeline_role_arns, var.network_deploy_role_arn)
    )
    error_message = join(" ", [
      "network_deploy_role_arn (${var.network_deploy_role_arn}) khong nam trong",
      "network_pipeline_role_arns (${join(", ", var.network_pipeline_role_arns)}).",
      "Role CodeBuild se khong duoc phep assume no, va loi chi hien ra luc",
      "pipeline chay duoi dang AccessDenied cua STS.",
    ])
  }
}

########################################
# BAT STAGE THI PHAI CO ROLE
#
# Stage duoc bat ma khong co role nghia la provider chay bang credential
# cua CodeBuild - tuc account MANAGEMENT. Luc do precondition trong
# network/ops/main.tf dung plan lai, nen khong co gi bi tao sai cho. Bat
# o day chi de loi den som hon mot vong, kem ten bien.
########################################
check "stage_bat_thi_co_role" {
  assert {
    condition = (
      !var.enable ||
      !(var.enable_network_stage || var.enable_firewall_stage) ||
      var.network_deploy_role_arn != ""
    )
    error_message = join(" ", [
      "Stage cua pipeline nay dang duoc bat nhung network_deploy_role_arn rong.",
      "Provider cua layer network/ops se chay bang credential cua CodeBuild,",
      "tuc account management - va precondition trong layer do se dung plan lai",
      "voi thong bao 'SAI ACCOUNT'.",
    ])
  }
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

  ####################################
  # VERIFY - HAI CHIEU, VA CHE DO TU SINH RA TU HAI CO enable_*
  #
  # =================================================================
  # VI SAO KHONG CO BIEN "network_dang_rong"
  #
  # Ha tang network hien dang RONG (state 0 resource) va se duoc dung lai.
  # Nen phep kiem phai dung o CA HAI trang thai, va phai biet dang o trang
  # thai nao.
  #
  # Cach hien nhien la them mot bien khai bao - va do la cach SAI: mot bien
  # nhu vay lech duoc voi thuc te. Dung lai mang, bat hai stage, roi quen
  # doi bien thi phep kiem se doi resource VANG MAT trong khi chung dang
  # duoc apply moi lan.
  #
  # Nen che do duoc SUY RA tu chinh hai co quyet dinh stage co chay hay
  # khong. Khong co gi de quen, va khong co gi de lech.
  #
  # =================================================================
  # HAI CHIEU, VA CA HAI DEU BAO DUOC
  #
  #   chua-dung  hai stage tat -> KHONG duoc thay rule group hay alarm.
  #              Thay thi CANH BAO: co ha tang dang song ma khong pipeline
  #              nao quan - thay doi o do khong qua gate.py, khong qua cong
  #              duyet, va drift hang dem khong doc layer nay.
  #
  #   da-dung    stage bat -> rule group phai ton tai, PHAI duoc mot
  #              firewall policy doc toi, va hai alarm phai co nguoi nhan.
  #
  # Chieu thu nhat la chieu nguoi ta khong nghi toi, va no la chieu dang
  # xay ra hom nay.
  #
  # =================================================================
  # PHEP KIEM DANG GIA NHAT O DAY: "TON TAI" KHAC "DUOC DOC TOI"
  #
  # network/ops co check "rule_group_is_referenced", nhung no so ARN voi
  # BIEN ops_rule_group_arns cua layer cha - tuc kiem mot LOI KHAI. Sua
  # firewall policy o console thi bien van khop va check van xanh, trong khi
  # rule group khong con duoc doc toi: moi luong truoc day bi chan gio di
  # qua, va khong co log nao noi mot luat vua ngung co hieu luc.
  #
  # Script doc firewall policy TU AWS nen no thay. Cung ho voi loi 126.
  #
  # =================================================================
  # LUU Y: verify.sh CO SAN KHONG DUNG DUOC O DAY
  #
  # landing-zone/network/verify.sh doc `terraform output`, tuc doc STATE -
  # ma buildspec-verify.yml CO Y khong cai Terraform va khong doc state. Va
  # no kiem layer network GOC, con pipeline nay apply network/ops. Hai tap
  # khac nhau, khong phai trung lap.
  ####################################
  # =================================================================
  # NHAY DON QUANH ARN - KHONG PHAI TRANG TRI
  #
  # network_deploy_role_arn CO THE rong (mac dinh la vay). Khong co nhay thi buildspec
  # `eval` thay
  #
  #   ./landing-zone/network/kiem-mang.sh  chua-dung
  #
  # va bash GOP khoang trang: $1 thanh "chua-dung", $2 rong, script thoat 2
  # voi mot loi ve "che do khong hop le" khong nhac gi toi ARN.
  #
  # kiem-config.sh khong vuong vi ARN la tham so CUOI o do; o day no dung
  # giua nen phai giu cho.
  #
  # Da tai hien:
  #   eval "/tmp/t.sh  chua-dung"      -> $1='chua-dung' $2=''
  #   eval "/tmp/t.sh '' chua-dung"    -> $1=''          $2='chua-dung'
  # =================================================================
  verify = "./landing-zone/network/kiem-mang.sh '${var.network_deploy_role_arn}' ${var.enable_network_stage || var.enable_firewall_stage ? "da-dung" : "chua-dung"}"

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
