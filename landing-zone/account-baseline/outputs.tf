########################################
# SINH CAU HINH CHO LAYER KHAC
#
# Layer nay KHONG sua duoc terraform.tfvars cua layer khac - moi
# layer co state rieng, va tfvars nam trong .gitignore.
#
# Nhung no biet du de SINH RA khoi HCL cho ban dan vao, va quan
# trong hon: canh bao khi co account chua duoc khai o dau ca.
#
# Do la buoc 3 trong ba viec tay - buoc duy nhat khong tu dong hoa
# duoc, nen thay vao do lam cho no KHONG THE QUEN.
########################################

locals {
  active_accounts = [
    for a in data.aws_organizations_organization.this.accounts :
    a.id if a.status == "ACTIVE"
  ]

  mgmt = data.aws_caller_identity.current.account_id

  ########################################
  # SCOPE: HAI NGUON, KHONG PHAI MOT
  #
  # var.account_scopes  go tay, cho account co TRUOC catalog
  # catalog `scope:`    do nguoi mo request khai, BAT BUOC (lint chan)
  #
  # Truoc day chi doc nguon thu nhat. Hau qua o dung lan apply tao
  # account: paste_permission_sets in ra danh sach KHONG CO account
  # vua tao, nen ai dan no sang permission-sets se cap quyen cho
  # nhung account cu va bo qua nhung account moi - tuc khong ai vao
  # duoc account vua tao qua Identity Center.
  #
  # Va thu dang le bat duoc chuyen do lai im: xem unmapped ben duoi.
  ########################################
  catalog_scope_by_name = {
    for a in local.catalog_raw : a.name => try(a.scope, "none")
  }

  catalog_scopes = {
    for name, acct in aws_organizations_account.this :
    acct.id => local.catalog_scope_by_name[name]
    if try(local.catalog_scope_by_name[name], "none") != "none"
  }

  # Catalog di SAU: no la ban ghi cua yeu cau, con account_scopes la
  # ban do go tay. Hai cho khai lech nhau thi lay cai o catalog.
  scopes_all = merge(var.account_scopes, local.catalog_scopes)

  # Account ACTIVE chua co mat trong scope nao. Management account
  # khong tinh - no khong thuoc pham vi workload nao.
  #
  # active_accounts DOC TU AWS, va o lan apply tao account no duoc doc
  # TRUOC khi account ton tai. Nen o dung lan chay dang can canh bao
  # nhat, danh sach nay RONG - va "rong" doc y het "moi thu deu on".
  # Gop catalog_scopes vao la de con so khong con phu thuoc vao thoi
  # diem doc data source.
  unmapped = sort([
    for id in local.active_accounts :
    id if id != local.mgmt && !contains(keys(local.scopes_all), id)
  ])

  by_scope = {
    for s in ["analytics", "nonprod", "prod"] :
    s => sort([for id, sc in local.scopes_all : id if sc == s])
  }
}

output "unmapped_accounts" {
  description = <<-EOT
    Account ACTIVE chua khai pham vi o dau ca - khong trong
    var.account_scopes, khong trong truong `scope` cua catalog.

    KHONG rong = co account khong ai biet no thuoc pham vi nao, va
    gan nhu chac chan chua co trong accounts_by_scope ben
    permission-sets - tuc khong ai vao duoc no qua Identity Center.

    RONG KHONG PHAI LA BANG CHUNG o lan apply VUA TAO account:
    danh sach account ACTIVE doc tu AWS bang data source, ma data
    source duoc doc TRUOC khi account ton tai. Account vua tao khong
    nam trong do, nen no khong the bi diem danh la thieu.

    Chay lai `terraform plan` mot lan nua sau khi apply thi con so moi
    tinh tren thuc te.
  EOT
  value       = local.unmapped
}

output "paste_permission_sets" {
  description = <<-EOT
    Dan vao landing-zone/permission-sets/terraform.tfvars

    Sinh tu account_scopes, nen no phan anh dung y dinh cua ban chu
    khong phai suy doan tu cay OU.
  EOT
  value = join("\n", concat(
    ["accounts_by_scope = {"],
    [for s in ["analytics", "nonprod", "prod"] :
      format("  %-9s = [%s]", s, join(", ", [for id in local.by_scope[s] : "\"${id}\""]))
    ],
    ["}"],
  ))
}

output "paste_config_detective" {
  description = <<-EOT
    Dan vao landing-zone/config-detective/terraform.tfvars

    Moi account ACTIVE khong nam trong recorder_target_ous PHAI co
    mat trong excluded_accounts, neu khong organization rule se ngoi
    CREATE_IN_PROGRESS hang chuc phut roi CREATE_FAILED.

    Danh sach duoi day gom management account (luon phai loai tru) va
    cac account pham vi nonprod - noi thuong khong bat recorder de
    tiet kiem. DOI CHIEU LAI voi recorder_target_ous cua ban truoc
    khi dung.
  EOT
  value = join("\n", concat(
    ["excluded_accounts = ["],
    [format("  \"%s\",   # management", local.mgmt)],
    [for id in local.by_scope["nonprod"] : format("  \"%s\",   # nonprod - kiem lai recorder_target_ous", id)],
    ["]"],
  ))
}

########################################
# Trang thai
########################################

output "enabled" {
  value = local.enabled
}

output "sweep_stack_set" {
  value = local.enabled ? aws_cloudformation_stack_set.baseline[0].name : null
}

output "created_accounts" {
  description = "Account do layer nay tao. Rong neu tao tay."
  value = {
    for k, a in aws_organizations_account.this : k => {
      id        = a.id
      parent_id = a.parent_id
    }
  }
}

output "next_steps" {
  value = <<-EOT

    ══════════════════════ SAU KHI APPLY ══════════════════════

    1. STACKSET DA TOI CAC ACCOUNT CHUA (~5 phut):

         aws cloudformation list-stack-instances \
           --stack-set-name ${var.project}-account-baseline --call-as SELF \
           --query 'Summaries[].[Account,Status]' --output table

       Tat ca phai CURRENT.

    2. XEM NO XOA DUOC GI - day la buoc quan trong nhat:

         aws cloudformation describe-stacks \
           --profile <account> --region ${var.region} \
           --query "Stacks[?contains(StackName,'account-baseline')].Outputs[] | [?OutputKey=='SweepResult'].OutputValue" \
           --output text

       Dau [] sau Outputs la BAT BUOC. Khong co no thi JMESPath tao mot
       projection long va --output text in ra RONG - trong y het nhu
       stack khong co output nao, trong khi output van o do.

       Ket qua co ba dang:
         "ap-southeast-1/vpc-xxx"   da xoa
         "khong co default VPC nao" khong con gi - dung neu da don tay
         "us-east-1/SKIP:ClientError" bi tu choi, xem muc 3

    3. SKIP NGHIA LA GI:

       Gan nhu luon la region_lock SCP tu choi ec2:DeleteVpc o region
       ngoai allowed_regions. KHONG phai lo hong: default VPC o region
       bi khoa la vo hai, vi khong ai tao duoc gi o do.

       SKIP o region NAM TRONG allowed_regions thi moi la van de.

    4. KIEM DOC LAP - dung tin stack output, hoi thang AWS.
       Lap MOI region trong sweep_regions, khong chi region dang mo:

         for p in <cac profile>; do
           printf '%-16s ' "$p"
           for r in ${join(" ", var.sweep_regions)}; do
             printf '%s=%s ' "$r" "$(aws ec2 describe-vpcs --region $r \
               --profile $p --filters Name=isDefault,Values=true \
               --query 'length(Vpcs)' --output text)"
           done; echo
         done

       Tat ca phai ra 0. Vong lap MOT region chinh la thu da tao ra lo
       hong: lan don tay chi chay o mot region, va cau kiem chung cung
       chi hoi region do.

    5. DAN CAU HINH SANG LAYER KHAC:

         terraform output -raw paste_permission_sets
         terraform output -raw paste_config_detective
         terraform output unmapped_accounts

       unmapped_accounts KHONG RONG = co account chua ai khai pham vi.

    ═══════════════════════════════════════════════════════════

  EOT
}

########################################
# BUOC KHONG TU DONG HOA DUOC
#
# Attachment cua account workload xuat hien o ACCOUNT NETWORK, va
# layer nay khong voi toi do duoc. Sinh san khoi tfvars cho layer
# kia thay vi de nguoi ta tu di tim ID.
########################################

output "paste_spokes" {
  description = <<-EOT
    Dan vao terraform.tfvars cua landing-zone/network, roi apply ben do.

    manual_vpc = true la mau chot: no noi voi layer kia "VPC da co
    nguoi tao roi - dung tao nua, nhung VAN share RAM cho account nay
    va VAN noi attachment cua no vao rtb-spokes khi attachment xuat
    hien".

    Bo buoc nay thi VPC ton tai, attachment ton tai o trang thai
    available, va KHONG CO GOI TIN NAO DI DAU CA. Attachment khong
    nam trong route table nao thi no khong hoc duoc duong nao, va
    khong ai hoc duoc duong toi no. Trieu chung doc nhu mot loi dinh
    tuyen trong spoke - noi khong co gi sai ca.
  EOT
  value = length(local.spoke_requests) == 0 ? "(chua co account nao xin mang)" : join("\n", concat(
    ["spokes = {"],
    flatten([
      for k in sort(keys(local.spoke_requests)) : [
        "  \"${k}\" = {",
        "    cidr       = \"${local.spoke_requests[k].vpc_cidr}\"",
        "    account_id = \"${try(aws_organizations_account.this[k].id, "chua-tao")}\"",
        "    ou_id      = \"${try(var.ou_ids[local.spoke_requests[k].ou], "chua-biet")}\"",
        "    manual_vpc = true",
        "  }",
      ]
    ]),
    ["}"],
  ))
}

output "spoke_networks" {
  description = "Account nao nhan VPC nao, va no co noi vao luoi khong"
  value = {
    for k, v in local.spoke_requests : k => {
      account_id    = try(aws_organizations_account.this[k].id, "chua-tao")
      vpc_cidr      = v.vpc_cidr
      noi_tgw       = v.attach_tgw && try(local.net.transit_gateway_id, "") != ""
      dns_tap_trung = try(local.net.dns_profile_id, "") != ""
    }
  }
}
