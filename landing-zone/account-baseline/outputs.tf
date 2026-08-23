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

  # Account ACTIVE chua co mat trong account_scopes. Management account
  # khong tinh - no khong thuoc pham vi workload nao.
  unmapped = sort([
    for id in local.active_accounts :
    id if id != local.mgmt && !contains(keys(var.account_scopes), id)
  ])

  by_scope = {
    for s in ["analytics", "nonprod", "prod"] :
    s => sort([for id, sc in var.account_scopes : id if sc == s])
  }
}

output "unmapped_accounts" {
  description = <<-EOT
    Account ACTIVE chua khai trong account_scopes.

    KHONG rong = co account khong ai biet no thuoc pham vi nao, va
    gan nhu chac chan chua co trong accounts_by_scope ben
    permission-sets - tuc khong ai vao duoc no qua Identity Center.
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

    4. KIEM DOC LAP - dung tin stack output, hoi thang AWS:

         for p in <cac profile>; do
           printf '%-16s ' "$p"
           aws ec2 describe-vpcs --region ${var.region} \
             --filters Name=isDefault,Values=true \
             --query 'length(Vpcs)' --profile $p --output text
         done

       Tat ca phai ra 0.

    5. DAN CAU HINH SANG LAYER KHAC:

         terraform output -raw paste_permission_sets
         terraform output -raw paste_config_detective
         terraform output unmapped_accounts

       unmapped_accounts KHONG RONG = co account chua ai khai pham vi.

    ═══════════════════════════════════════════════════════════

  EOT
}
