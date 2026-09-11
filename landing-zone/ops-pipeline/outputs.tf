output "pipeline_name" {
  value = try(aws_codepipeline.ops[0].name, null)
}

output "pipeline_console_url" {
  value = local.enabled ? "https://${var.region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${local.name}/view?region=${var.region}" : null
}

output "codebuild_role_arn" {
  description = <<-EOT
    Role ma CodeBuild dung. HAI cho can biet no:

      1. var.scp_exempt_role_names o layer organization.
         BAT BUOC. ProtectOrganizationMembership chan
         organizations:DetachPolicy va DeletePolicy - hai hanh dong
         chinh pipeline nay phai goi duoc. Thieu mien tru thi pipeline
         apply duoc lan dau roi tu do khong sua duoc SCP nua, VA KHONG
         SUA DUOC BANG CHINH NO.

         Chi can TEN role, khong phai ARN:
           ${try(aws_iam_role.codebuild[0].name, "<chua apply>")}

      2. Bat ky SCP nao ban them sau nay ma chan mot hanh dong trong
         danh sach THIET_YEU cua organization/lint.sh.
  EOT
  value       = try(aws_iam_role.codebuild[0].arn, null)
}

output "codebuild_role_name" {
  description = "Dan thang vao scp_exempt_role_names cua layer organization."
  value       = try(aws_iam_role.codebuild[0].name, null)
}

output "drift_project" {
  description = <<-EOT
    Project phat hien drift. Chay tay:

      aws codebuild start-build --project-name <ten> --region ${var.region}

    No CHI plan -lock=false. Khong co nhanh apply trong buildspec.
  EOT
  value       = try(aws_codebuild_project.drift[0].name, null)
}

output "layers" {
  description = "Layer nao dang di qua pipeline nay, va khoa state cua tung cai."
  value       = local.stage_keys
}

output "next_steps" {
  value = local.next_steps
}
