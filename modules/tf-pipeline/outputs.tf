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
# SCP KHONG AP DUNG CHO MANAGEMENT ACCOUNT
#
# Role nay song o account management, va AWS KHONG ap SCP len principal
# o do - ke ca SCP gan vao Root. Nen ProtectOrganizationMembership
# (chan organizations:DetachPolicy va DeletePolicy) khong cham toi no,
# va KHONG can them ten nay vao scp_exempt_role_names.
#
# Ban dau khoi nay ghi nguoc lai va goi do la "buoc bat buoc". Sai.
# Chinh scp.tf da ghi dieu nay o dau file tu truoc: "SCP KHONG ap dung
# cho management account."
#
# CHO NAO THI MOI CAN MIEN TRU: khi principal nam o mot account THANH
# VIEN. Vi du role cua mot pipeline chay o account security de sua
# Config rule - role do bi SCP cua Root chan binh thuong.
########################################
output "codebuild_role_name" {
  description = "Ten role CodeBuild. Khong can mien tru SCP - role nay o management account."
  value = local.enabled ? {
    ten = aws_iam_role.codebuild[0].name

    scp = join(" ", [
      "KHONG can them vao scp_exempt_role_names: role nay o account management,",
      "va SCP khong ap dung cho principal o account management.",
    ])

    can_lam_gi = join(" ", [
      "Neu topic bao drift nam o ACCOUNT KHAC thi them ARN cua role nay vao",
      "bien extra_publisher_arns o ../config-detective - SNS lien account doi",
      "ca hai phia cho phep.",
    ])
  } : null
}

output "drift_project" {
  description = "Project phat hien drift. CHI plan -lock=false; buildspec khong co nhanh apply."
  value = local.enabled ? {
    ten    = aws_codebuild_project.drift[0].name
    lich   = var.drift_cron
    bao_ve = local.drift_topic == "" ? "KHONG BAO AI - chua khai drift_emails hay drift_topic_arn" : local.drift_topic
    chay_tay = join(" ", [
      "aws codebuild start-build --project-name",
      aws_codebuild_project.drift[0].name,
      "--region", var.region,
    ])
  } : null
}

output "cong_duyet" {
  description = "Stage nao dung lai cho nguoi bam, va ai duoc bao."
  value = local.enabled ? {
    stage = var.approve_stages
    topic = try(aws_sns_topic.approval[0].arn, "(khong co stage nao can duyet)")

    # Terraform bao tao subscription thanh cong ke ca khi chua ai bam xac
    # nhan. Nen state KHONG tra loi duoc cau hoi "co ai duoc bao khong".
    kiem_ai_duoc_bao = length(var.approve_stages) == 0 ? "(khong can)" : join(" ", [
      "aws sns list-subscriptions-by-topic --topic-arn",
      try(aws_sns_topic.approval[0].arn, ""),
      "--query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output text",
      "# SubscriptionArn = PendingConfirmation -> chua bam, se KHONG nhan thu",
    ])
  } : null
}

output "layers" {
  description = "Layer nao dang di qua pipeline nay, va khoa state cua tung cai."
  value       = local.stage_keys
}

output "ten" {
  description = "Ten day du cua pipeline. Di vao ten moi resource, nen no phai duy nhat trong account."
  value       = local.name
}

output "stages" {
  description = "Stage dang bat, theo thu tu chay, kem thu tu action."
  value = [for s in local.stages : {
    key      = s.key
    layer    = s.layer
    thu_tu   = s.thu_tu
    co_duyet = s.co_duyet
  }]
}

output "next_steps" {
  value = local.next_steps
}
