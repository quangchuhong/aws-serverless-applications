output "enabled" {
  value = local.enabled
}

output "catalog_account_id" {
  description = "Account dang giu portfolio"
  value       = data.aws_caller_identity.current.account_id
}

output "tag_options" {
  description = "TagOption da tao, va key nao thuc su BUOC nguoi dung chon"
  value = {
    total = length(local.tag_option_pairs)

    # Key co tu 2 gia tri tro len. Chi nhung key nay moi ep duoc -
    # key mot gia tri thi tag tu gan, va do la viec default_tags
    # da lam roi.
    forcing_choice = sort(local.keys_forcing_choice)

    by_key = { for k, v in var.tag_options : k => length(v) if length(v) > 0 }
  }
}

output "portfolios" {
  value = {
    for k, p in aws_servicecatalog_portfolio.this : k => {
      id  = p.id
      arn = p.arn
    }
  }
}

output "launch_role_arn" {
  description = "Role Service Catalog dung de tao resource. Khai vao aws_servicecatalog_constraint type LAUNCH."
  value       = try(aws_iam_role.sc_launch[0].arn, null)
}

output "next_steps" {
  value = <<-EOT

    1. LAYER NAY CHUA TAO PRODUCT NAO.

       Product la thu rieng cua tung to chuc - mot template
       CloudFormation mo ta "RDS chuan cua cong ty", "S3 bucket chuan"...
       Chung khong thuoc ve Landing Zone.

       Layer nay dung phan KHUNG: TagOption, portfolio, chia se, va
       launch role. Them product:

         resource "aws_servicecatalog_product" "rds" {
           name  = "rds-chuan"
           owner = "Platform Engineering"
           type  = "CLOUD_FORMATION_TEMPLATE"

           provisioning_artifact_parameters {
             template_url = "https://<bucket>.s3.amazonaws.com/rds.yaml"
             type         = "CLOUD_FORMATION_TEMPLATE"
           }
         }

       Roi gan launch constraint - KHONG BO QUA BUOC NAY:

         resource "aws_servicecatalog_constraint" "rds" {
           portfolio_id = <portfolio id o output tren>
           product_id   = aws_servicecatalog_product.rds.id
           type         = "LAUNCH"
           parameters   = jsonencode({ RoleArn = <launch_role_arn> })
         }

    2. CAP QUYEN CHO NGUOI DUNG

       aws_servicecatalog_principal_portfolio_association gan permission
       set hoac role vao portfolio. Khong gan thi khong ai thay portfolio.

    3. THU HOI QUYEN TAO TRUC TIEP - buoc lam layer nay co nghia

       Chua thu hoi thi doi ung dung van tao resource bang console va
       TagOption khong ep duoc gi. Sua permission set ben
       landing-zone/permission-sets, hoac them SCP.

    4. KIEM CHUNG - phai launch that

         Console -> Service Catalog -> Products -> Launch

       Man hinh launch PHAI hoi ban chon gia tri cho tung key co nhieu
       gia tri. Khong hoi = TagOption chua toi noi, kiem lai
       share_tag_options.

  EOT
}
