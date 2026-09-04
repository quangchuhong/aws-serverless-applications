########################################
# DOC STATE CUA LAYER CHA
#
# Chi doc mot output: ops_handles. Xem ../outputs.tf.
#
# terraform_remote_state la QUYEN DOC state - khong phai quyen sua.
# Lop nay khong tao duoc mot resource nao trong state kia du co muon.
########################################

locals {
  ########################################
  # DUONG DAN STATE CUA LAYER CHA
  #
  # path.module, KHONG phai mot duong dan tuong doi tran.
  #
  # Backend local cua terraform_remote_state giai duong dan tuong doi
  # theo THU MUC DANG CHAY, khong theo thu muc chua file .tf. Hai cai
  # do trung nhau khi go `cd ops && terraform apply`, va lech nhau
  # khi go `terraform -chdir=ops apply`, khi chay tu CI voi
  # working-directory khac, hay khi lop nay duoc goi nhu mot module.
  #
  # Luc lech, loi la:
  #
  #   Error: Unable to find remote state
  #   No stored state was found for the given workspace in the given backend.
  #
  # Cau do khong nhac gi toi duong dan, khong in ra duong dan da thu,
  # va doc y het nhu "layer cha chua bao gio duoc apply" - trong khi
  # state nam ngay day, chi la Terraform dang tim tu mot thu muc khac.
  ########################################

  state_config = var.state_backend != "local" ? var.state_config : {
    path = lookup(var.state_config, "path", "${path.module}/../terraform.tfstate")
  }
}

data "terraform_remote_state" "hub" {
  backend = var.state_backend
  config  = local.state_config
}

locals {
  hub = data.terraform_remote_state.hub.outputs.ops_handles
}

########################################
# DANH TINH DANG DUNG DE TAO RESOURCE
#
# KHONG cung mot thu voi danh tinh doc state.
#
# State nam trong mot bucket co the thuoc account khac (thuong la
# management), va backend co profile rieng. Con provider ben duoi thi
# giai credential theo chuoi mac dinh. Hai duong do doc lap nhau, va
# chung LECH NHAU rat de:
#
#   - backend khai profile, nhung bien moi truong de len profile
#   - shell vua chay lenh o account khac
#   - profile mac dinh la mot IAM user chi de day state len S3
#
# Khi lech, moi thu van chay: init thanh cong, doc state thanh cong,
# plan in ra day du. Chi co dieu resource se duoc tao o SAI ACCOUNT -
# rule group nam mot noi, firewall policy tham chieu no nam noi khac,
# va ARN thi khong bao gio khop.
#
# verify.sh va teardown.sh da phai dung dung chot chan nay (loi 58).
# Lop nay can no hon ca hai: no GHI, va no ghi vao mot account ma no
# tu suy ra chu khong ai go tay.
########################################

data "aws_caller_identity" "current" {}

########################################
# DOC CATALOG
#
# yamldecode tra ve null cho file chi co comment, va null[...] thi
# Terraform bao "Invalid index" o mot dong khong lien quan gi toi file
# YAML. try(..., []) de file rong doc ra danh sach rong - trang thai
# hop le, nghia la "chua co rule nao".
########################################

locals {
  apps_raw      = try(yamldecode(file("${path.module}/${var.catalog_dir}/apps.yaml")).apps, [])
  fw_raw        = try(yamldecode(file("${path.module}/${var.catalog_dir}/firewall-rules.yaml")).rules, [])
  routes_raw    = try(yamldecode(file("${path.module}/${var.catalog_dir}/routes.yaml")).routes, [])
  endpoints_raw = try(yamldecode(file("${path.module}/${var.catalog_dir}/endpoints.yaml")).endpoints, [])
  dns_raw       = try(yamldecode(file("${path.module}/${var.catalog_dir}/dns-records.yaml")).records, [])
}

########################################
# GIAI TEN APP -> CIDR
#
# DAY LA LY DO CHINH CUA CA LOP NAY.
#
# east_west_rules ben layer cha khai bang CIDR tho:
#
#   from_cidr = "10.10.0.0/16"
#
# Go nham mot chu so - "10.10.0.0/16" trong khi spoke that la
# "10.11.0.0/16" - va chuyen gi xay ra? Terraform apply thanh cong.
# Rule duoc nap. Firewall chay. Va rule do khong khop mot goi tin nao
# tron doi. Khong co loi, khong co canh bao, khong co dong log nao noi
# "rule 1003 chua bao gio khop". Nguoi mo ticket bao van khong ket
# noi duoc, va cho dau tien ai cung nhin la route va security group.
#
# Ta da gap dung kieu im lang do o cho khac: spoke doi ten tu app-dev
# thanh probe va hai muc kiem chung khong in gi ca (loi 62).
#
# Khai bang TEN thi go nham la Terraform dung ngay o plan, kem theo
# danh sach ten hop le. Loi to va som, thay cho im lang va muon.
########################################

locals {
  # CIDR khong the khop cai gi. Dung lam gia tri thay the khi khong
  # giai duoc ten, de neu no lot qua duoc guard ben duoi thi hau qua
  # la mot rule vo hai chu KHONG phai mot rule mo toang.
  #
  # Doi lai voi 0.0.0.0/0 - lua chon "an toan" theo ban nang nhung
  # nguoc han: mot rule pass toi 0.0.0.0/0 la mo het.
  unresolvable = "0.0.0.0/32"

  apps = {
    for a in local.apps_raw : a.name => {
      name  = a.name
      spoke = try(a.spoke, null)
      owner = try(a.owner, "chua khai")
      note  = try(a.note, "")

      # Spoke co that trong layer cha khong
      spoke_known = contains(keys(local.hub.spokes), try(a.spoke, ""))

      # cidr khai tay -> thu hep xuong host/subnet trong spoke.
      # Khong khai -> lay ca CIDR cua spoke.
      cidr = try(a.cidr, null) != null ? a.cidr : try(
        local.hub.spokes[a.spoke].cidr,
        local.unresolvable,
      )

      narrowed = try(a.cidr, null) != null
      account  = try(local.hub.spokes[a.spoke].account_id, null)
    }
  }

  app_names = sort(keys(local.apps))

  # App khai spoke khong ton tai. Guard ben duoi doc bang nay.
  apps_bad_spoke = [for k, v in local.apps : k if !v.spoke_known]

  # App khai cidr rieng NHUNG cidr do khong nam trong spoke cua no.
  #
  # Dang sai nay nguy hiem hon go nham ten: rule VAN khop cai gi do,
  # chi la khop nham mang. "Thu hep order-api xuong mot subnet" ma go
  # 10.21 thay vi 10.20 thi ban vua mo mot luong toi mot VPC khac.
  #
  # Terraform khong co ham kiem tra bao ham CIDR. Cach lam dung: lay
  # dia chi mang cua CIDR con, DEO LAI mat na cua CIDR cha, va so voi
  # dia chi mang cua cha.
  #
  #   con 10.20.5.0/24, cha 10.20.0.0/16
  #   -> cidrhost("10.20.5.0/16", 0) = "10.20.0.0" = cidrhost(cha, 0)  OK
  #
  #   con 10.21.5.0/24, cha 10.20.0.0/16
  #   -> cidrhost("10.21.5.0/16", 0) = "10.21.0.0" != "10.20.0.0"      SAI
  #
  # Kem dieu kien do dai tien to: mot /8 khong nam trong mot /16 du
  # dia chi mang trung nhau.
  apps_cidr_outside = [
    for k, v in local.apps : k
    if v.narrowed && v.spoke_known && !(
      can(cidrhost(v.cidr, 0))
      && tonumber(split("/", v.cidr)[1]) >= tonumber(split("/", local.hub.spokes[v.spoke].cidr)[1])
      && cidrhost(
        "${split("/", v.cidr)[0]}/${split("/", local.hub.spokes[v.spoke].cidr)[1]}", 0
      ) == cidrhost(local.hub.spokes[v.spoke].cidr, 0)
    )
  ]
}

########################################
# CHOT AN TOAN
#
# terraform_data + precondition, KHONG phai check block.
#
# check chi CANH BAO - apply van chay tiep. Dung cho nhung thu "nen
# xem lai". Nhung mot rule tro toi app khong ton tai thi khong co gi
# de xem lai: no sai, va apply khong duoc phep di tiep.
#
# precondition dung plan lai voi thong bao cua minh, truoc khi AWS
# nhin thay bat cu thu gi.
########################################

resource "terraform_data" "catalog_guard" {
  # Bat plan chay lai guard khi catalog doi
  input = {
    apps      = length(local.apps_raw)
    rules     = length(local.fw_raw)
    routes    = length(local.routes_raw)
    endpoints = length(local.endpoints_raw)
    records   = length(local.dns_raw)
  }

  ########################################
  # apps.yaml
  ########################################

  lifecycle {
    ########################################
    # ACCOUNT - kiem TRUOC moi thu khac
    ########################################

    precondition {
      condition = data.aws_caller_identity.current.account_id == local.hub.account_id
      error_message = join(" ", [
        "SAI ACCOUNT.",
        "State cua layer cha noi ha tang mang nam o account ${local.hub.account_id},",
        "nhung provider dang goi AWS bang ${data.aws_caller_identity.current.account_id}",
        "(${data.aws_caller_identity.current.arn}).",
        "Apply se tao rule group, route va ban ghi DNS o SAI ACCOUNT - hoac that bai giua chung.",
        "Chu y: danh tinh doc state va danh tinh tao resource la HAI duong khac nhau;",
        "backend co the dung profile nay con provider dung credential khac.",
        "Sua bang var.aws_profile, hoac dat lai bien moi truong AWS_* cho dung account.",
      ])
    }

    precondition {
      condition     = length(local.apps_bad_spoke) == 0
      error_message = "apps.yaml: ${join(", ", local.apps_bad_spoke)} khai spoke khong co trong layer cha. Spoke hop le: ${join(", ", sort(keys(local.hub.spokes)))}"
    }

    precondition {
      condition     = length(local.apps_raw) == length(distinct([for a in local.apps_raw : a.name]))
      error_message = "apps.yaml: co ten app trung. Ten la khoa - trung thi mot dinh nghia am tham de len cai kia va rule tro toi ten do khong con doan duoc no lay CIDR nao."
    }

    precondition {
      condition     = length(local.apps_cidr_outside) == 0
      error_message = "apps.yaml: ${join(", ", local.apps_cidr_outside)} khai cidr NAM NGOAI spoke cua no. Rule dung app nay se van khop luu luong - chi la khop nham mang khac. Bo truong cidr de lay ca CIDR cua spoke, hoac sua lai cho dung."
    }

    ########################################
    # firewall-rules.yaml
    ########################################

    precondition {
      condition     = length(local.fw_bad_id) == 0
      error_message = "firewall-rules.yaml: id sai dinh dang: ${join(", ", local.fw_bad_id)}. Phai la fw-NNNN voi NNNN tu 0001 den 8999. id sinh ra sid, va sid la thu noi mot dong trong log alert ve dung mot dong trong YAML."
    }

    precondition {
      condition     = length(local.fw_raw) == length(distinct([for r in local.fw_raw : try(r.id, "")]))
      error_message = "firewall-rules.yaml: co id trung. Hai rule cung sid thi Suricata NAP RULE DAU VA BO IM LANG rule sau - luong ban vua mo se khong hoat dong, va rules_string trong console van hien du ca hai dong."
    }

    precondition {
      condition     = length(local.fw_unknown_app) == 0
      error_message = "firewall-rules.yaml: tro toi app chua khai trong apps.yaml: ${join(", ", local.fw_unknown_app)}. App da khai: ${join(", ", local.app_names)}"
    }

    precondition {
      condition     = length(local.fw_bad_port) == 0
      error_message = "firewall-rules.yaml: port khong hop le o ${join(", ", local.fw_bad_port)}. Port trong khoang 1..65535, va rule icmp thi KHONG khai port."
    }

    precondition {
      condition     = length(local.fw_self) == 0
      error_message = "firewall-rules.yaml: ${join(", ", local.fw_self)} co from va to giai ra CUNG mot CIDR. Luu luong trong CUNG mot VPC khong di qua TGW nen khong bao gio toi firewall - rule nay se khong khop gi. Neu y ban la chan/mo giua hai host trong cung VPC thi do la viec cua security group."
    }

    precondition {
      condition     = var.allow_expired_rules || length(local.fw_expired) == 0
      error_message = "firewall-rules.yaml: rule DA QUA HAN: ${join(", ", local.fw_expired)}. Go chung di, hoac gia han truong expires. Muon apply tam thi dat allow_expired_rules = true."
    }

    ########################################
    # routes.yaml
    ########################################

    precondition {
      condition     = length(local.rt_bad_table) == 0
      error_message = "routes.yaml: bang khong ton tai o ${join(", ", local.rt_bad_table)}. Bang hop le: ${join(", ", sort(keys(local.hub.route_tables)))}"
    }

    precondition {
      condition     = length(local.rt_reserved) == 0
      error_message = "routes.yaml: ${join(", ", local.rt_reserved)} khai lai mot route DO LAYER CHA SO HUU. Hai aws_ec2_transit_gateway_route cung bang + cung dich thi cai apply sau bi AWS tu choi, va neu no lot thi mot trong hai state se giu mot route khong con dung nua."
    }

    precondition {
      condition     = length(local.rt_bad_target) == 0
      error_message = "routes.yaml: target khong giai duoc o ${join(", ", local.rt_bad_target)}. Dang cho phep: blackhole | spoke:<ten> | hub:<egress|security|ingress> | attachment:<tgw-attach-...>"
    }

    ########################################
    # endpoints.yaml
    ########################################

    precondition {
      condition     = length(local.vpce_duplicate) == 0
      error_message = "endpoints.yaml: ${join(", ", local.vpce_duplicate)} da duoc LAYER CHA tao qua interface_endpoint_services. Tao them cai thu hai la them mot bo ENI, them mot hoa don, va them mot PHZ cung ten che mat PHZ dang chay."
    }

    precondition {
      condition     = length(local.endpoints_raw) == 0 || local.hub.endpoints.enabled
      error_message = "endpoints.yaml co ${length(local.endpoints_raw)} dich vu nhung layer cha dang tat interface endpoint (enable_interface_endpoints = false). Chua co subnet endpoint, chua co security group, chua co gi de gan vao."
    }

    ########################################
    # dns-records.yaml
    ########################################

    precondition {
      condition     = length(local.dns_raw) == 0 || local.hub.dns.enabled
      error_message = "dns-records.yaml co ban ghi nhung layer cha dang tat PHZ noi bo (enable_internal_dns = false). Khong co zone de ghi vao."
    }

    precondition {
      condition     = length(local.dns_collide) == 0
      error_message = "dns-records.yaml: ${join(", ", local.dns_collide)} trung ten voi ban ghi DO LAYER CHA SINH RA. Hai aws_route53_record cung ten trong hai state khac nhau: cai apply sau ghi de cai truoc, ca hai plan deu sach, va ten do se nhay qua nhay lai moi lan mot trong hai layer chay."
    }

    precondition {
      condition     = length(local.dns_external_ip) == 0
      error_message = "dns-records.yaml: ${join(", ", local.dns_external_ip)} tro toi IP NGOAI ${local.hub.internal_supernet}. PHZ noi bo tra IP ngoai thuong la go nham. Neu dung la y ban, them allow_external: true vao ban ghi do."
    }

    precondition {
      condition     = length(local.dns_bad_type) == 0
      error_message = "dns-records.yaml: kieu ban ghi khong ho tro o ${join(", ", local.dns_bad_type)}. Ho tro: A, AAAA, CNAME, TXT, SRV."
    }
  }
}
