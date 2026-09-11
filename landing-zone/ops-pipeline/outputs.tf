########################################
# Re-export tu module.
#
# LUU Y CU PHAP: `description` cua output phai la CHUOI LITERAL - khong
# noi suy, khong goi ham. Terraform danh gia no o giai doan chua co bien
# nao, va no hong ngay o `terraform init`, truoc ca validate.
# Xem landing-zone/kiem-cu-phap.sh.
########################################

output "pipeline_name" {
  value = module.pipeline.pipeline_name
}

output "pipeline_console_url" {
  value = module.pipeline.pipeline_console_url
}

output "codebuild_role_arn" {
  description = "ARN role ma CodeBuild dung."
  value       = module.pipeline.codebuild_role_arn
}

output "codebuild_role_name" {
  description = "Ten role CodeBuild. Khong can mien tru SCP - role nay o management account."
  value       = module.pipeline.codebuild_role_name
}

output "drift_project" {
  description = "Project phat hien drift. CHI plan -lock=false."
  value       = module.pipeline.drift_project
}

output "cong_duyet" {
  description = "Stage nao dung lai cho nguoi bam, va ai duoc bao."
  value       = module.pipeline.cong_duyet
}

output "layers" {
  description = "Layer nao dang di qua pipeline nay, va khoa state cua tung cai."
  value       = module.pipeline.layers
}

output "stages" {
  description = "Stage dang bat, theo thu tu chay."
  value       = module.pipeline.stages
}

output "next_steps" {
  value = module.pipeline.next_steps
}
