########################################
# OUTPUT
#
# LUU Y CU PHAP: `description` cua output (va cua variable) phai la
# CHUOI LITERAL. Khong noi suy, khong goi ham - Terraform danh gia no o
# giai doan chua co bien nao. `${var.region}` hay `${try(...)}` trong mo
# ta cho ra:
#
#   Error: Variables not allowed
#   Error: Function calls not allowed
#   Error: Unsuitable value type - value must be known
#
# Va no hong ngay o `terraform init`, truoc ca validate.
#
# Cho can gia tri dong thi dat vao `value`, hoac vao local.next_steps -
# o do noi suy duoc binh thuong.
########################################

output "pipeline_name" {
  value = try(aws_codepipeline.ops[0].name, null)
}

output "pipeline_console_url" {
  value = local.enabled ? "https://${var.region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${local.name}/view?region=${var.region}" : null
}

output "codebuild_role_arn" {
  description = "ARN role ma CodeBuild dung. Xem codebuild_role_name cho buoc bat buoc sau apply."
  value       = try(aws_iam_role.codebuild[0].arn, null)
}

########################################
# BUOC BAT BUOC SAU APPLY
#
# Ten role nay phai vao var.scp_exempt_role_names cua layer
# organization. Mo ta day du nam trong value, khong trong description -
# xem ghi chu cu phap o dau file.
########################################
output "codebuild_role_name" {
  description = "Ten role CodeBuild. PHAI them vao scp_exempt_role_names cua layer organization."
  value = local.enabled ? {
    ten = aws_iam_role.codebuild[0].name

    viec_phai_lam = join(" ", [
      "Them ten nay vao var.scp_exempt_role_names o ../organization/terraform.tfvars",
      "roi apply layer do.",
    ])

    vi_sao_bat_buoc = join(" ", [
      "Statement ProtectOrganizationMembership chan organizations:DetachPolicy va",
      "organizations:DeletePolicy - hai hanh dong ma chinh pipeline nay phai goi",
      "duoc de sua SCP. Thieu mien tru thi pipeline apply duoc LAN DAU (luc SCP",
      "chua gan), roi tu do khong sua duoc SCP nua - VA KHONG SUA DUOC BANG",
      "CHINH NO. Phai vao bang tay de go.",
    ])
  } : null
}

output "drift_project" {
  description = "Project phat hien drift. CHI plan -lock=false; buildspec khong co nhanh apply."
  value = local.enabled ? {
    ten    = aws_codebuild_project.drift[0].name
    lich   = var.drift_cron
    bao_ve = var.drift_topic_arn == "" ? "KHONG BAO AI - drift_topic_arn de rong" : var.drift_topic_arn
    chay_tay = join(" ", [
      "aws codebuild start-build --project-name",
      aws_codebuild_project.drift[0].name,
      "--region", var.region,
    ])
  } : null
}

output "layers" {
  description = "Layer nao dang di qua pipeline nay, va khoa state cua tung cai."
  value       = local.stage_keys
}

output "next_steps" {
  value = local.next_steps
}
