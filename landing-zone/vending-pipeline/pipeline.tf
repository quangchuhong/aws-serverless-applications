########################################
# THU DUYET
########################################

resource "aws_sns_topic" "approval" {
  count = local.enabled ? 1 : 0

  name = "${local.name}-duyet"
  tags = { Name = "${local.name}-duyet" }
}

resource "aws_sns_topic_subscription" "approval" {
  for_each = local.enabled ? toset(var.approval_emails) : toset([])

  topic_arn = aws_sns_topic.approval[0].arn
  protocol  = "email"
  endpoint  = each.value

  # Moi dia chi phai bam xac nhan trong thu dau tien. Truoc do
  # subscription o trang thai PendingConfirmation va KHONG nhan gi -
  # va Terraform van bao tao thanh cong.
}

resource "aws_sns_topic_policy" "approval" {
  count = local.enabled ? 1 : 0

  arn = aws_sns_topic.approval[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.pipeline[0].arn }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.approval[0].arn
    }]
  })
}

########################################
# PIPELINE
#
# Moi stage cua local.stages tro thanh BA action:
#
#   1. plan     CodeBuild, sinh tfplan + tfplan.txt
#   2. duyet    Manual approval, dinh kem link toi log
#   3. apply    CodeBuild, chay `terraform apply tfplan`
#
# Stage nao co wait = true thi co them mot action cho DAT TRUOC plan -
# khong phai truoc apply. Ly do: plan cua layer network doc data
# source loc `state = available`, nen no phai chay SAU khi attachment
# san sang. Cho sau plan thi plan da tinh tren du lieu cu roi.
########################################

resource "aws_codepipeline" "vending" {
  count = local.enabled ? 1 : 0

  name     = local.name
  role_arn = aws_iam_role.pipeline[0].arn

  # V2: cho phep dat bien o cap pipeline va co lich chay. Khong dung
  # tinh nang nao cua V2 ngay bay gio, nhung V1 khong nang cap tai cho
  # duoc - doi sau la tao lai ca pipeline.
  pipeline_type = "V2"

  artifact_store {
    location = aws_s3_bucket.artifacts[0].bucket
    type     = "S3"

    encryption_key {
      id   = aws_kms_key.artifacts[0].arn
      type = "KMS"
    }
  }

  ####################################
  # NGUON
  ####################################
  stage {
    name = "Nguon"

    action {
      name             = "Nguon"
      category         = "Source"
      owner            = "AWS"
      provider         = var.source_type == "codecommit" ? "CodeCommit" : "S3"
      version          = "1"
      output_artifacts = ["nguon"]

      configuration = var.source_type == "codecommit" ? {
        RepositoryName = var.repository_name
        BranchName     = var.branch_name

        # Poll = false: dung EventBridge, khong hoi lien tuc. Poll lam
        # pipeline cham toi 5 phut va tinh tien cho moi lan hoi.
        PollForSourceChanges = "false"
        } : {
        S3Bucket             = var.source_bucket
        S3ObjectKey          = var.source_object_key
        PollForSourceChanges = "false"
      }
    }
  }

  ####################################
  # LINT - khong can AWS, chay truoc moi thu
  #
  # Dat rieng mot stage chu khong gop vao stage A: mot catalog sai cu
  # phap khong nen di qua mot cong duyet roi moi hong.
  ####################################
  stage {
    name = "Lint"

    action {
      name            = "Lint"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["nguon"]

      configuration = {
        ProjectName = aws_codebuild_project.lint[0].name
      }
    }
  }

  ####################################
  # SAU STAGE, SINH TU local.stages
  ####################################
  dynamic "stage" {
    for_each = { for i, s in local.stages : s.key => merge(s, { thu_tu = i }) }

    content {
      name = replace(stage.value.key, "-", "_")

      # --- cho attachment (chi stage D) ---
      dynamic "action" {
        for_each = stage.value.wait ? [1] : []
        content {
          name            = "Cho_attachment"
          category        = "Build"
          owner           = "AWS"
          provider        = "CodeBuild"
          version         = "1"
          run_order       = 1
          input_artifacts = ["nguon"]

          configuration = {
            ProjectName = aws_codebuild_project.cho_attachment[0].name
          }
        }
      }

      # --- plan ---
      action {
        name             = "Plan"
        category         = "Build"
        owner            = "AWS"
        provider         = "CodeBuild"
        version          = "1"
        run_order        = stage.value.wait ? 2 : 1
        input_artifacts  = ["nguon"]
        output_artifacts = ["plan_${replace(stage.value.key, "-", "_")}"]

        configuration = {
          ProjectName = aws_codebuild_project.terraform[0].name
          EnvironmentVariables = jsonencode([
            { name = "LAYER_DIR", value = stage.value.layer, type = "PLAINTEXT" },
            { name = "STATE_KEY", value = local.stage_keys[stage.value.layer], type = "PLAINTEXT" },
            { name = "TF_ACTION", value = "plan", type = "PLAINTEXT" },
            {
              name  = "TF_TARGETS"
              value = join(" ", try(stage.value.targets, []))
              type  = "PLAINTEXT"
            },
            {
              name  = "ASSUME_ROLE_ARN"
              value = stage.value.assume ? var.network_deploy_role_arn : ""
              type  = "PLAINTEXT"
            },
          ])
        }
      }

      # --- duyet ---
      #
      # Khong co input_artifacts: manual approval khong doc duoc file.
      # Nguoi duyet phai mo log CodeBuild de xem plan. Do la mot buoc
      # them, va no co chu dich - mot cong duyet ma noi dung hien ngay
      # trong thu se duoc bam tu dien thoai, khong doc.
      action {
        name      = "Duyet"
        category  = "Approval"
        owner     = "AWS"
        provider  = "Manual"
        version   = "1"
        run_order = stage.value.wait ? 3 : 2

        configuration = {
          NotificationArn = aws_sns_topic.approval[0].arn
          CustomData      = "${stage.value.key}: ${stage.value.mo_ta} -- DOC PLAN trong log CodeBuild truoc khi duyet."
          ExternalEntityLink = format(
            "https://%s.console.aws.amazon.com/codesuite/codebuild/projects/%s/history?region=%s",
            var.region, aws_codebuild_project.terraform[0].name, var.region,
          )
        }
      }

      # --- apply ---
      action {
        name            = "Apply"
        category        = "Build"
        owner           = "AWS"
        provider        = "CodeBuild"
        version         = "1"
        run_order       = stage.value.wait ? 4 : 3
        input_artifacts = ["plan_${replace(stage.value.key, "-", "_")}"]

        configuration = {
          ProjectName = aws_codebuild_project.terraform[0].name
          EnvironmentVariables = jsonencode([
            { name = "LAYER_DIR", value = stage.value.layer, type = "PLAINTEXT" },
            { name = "STATE_KEY", value = local.stage_keys[stage.value.layer], type = "PLAINTEXT" },
            { name = "TF_ACTION", value = "apply", type = "PLAINTEXT" },

            # apply chay `terraform apply tfplan`, ma file plan da ghi
            # san pham vi target ben trong - nen dong nay khong doi
            # hanh vi. De o day de hai action doc giong nhau: mot ngay
            # nao do ai do sua nhanh apply va se can no.
            {
              name  = "TF_TARGETS"
              value = join(" ", try(stage.value.targets, []))
              type  = "PLAINTEXT"
            },
            {
              name  = "ASSUME_ROLE_ARN"
              value = stage.value.assume ? var.network_deploy_role_arn : ""
              type  = "PLAINTEXT"
            },
          ])
        }
      }
    }
  }
}

########################################
# KICH HOAT KHI CO COMMIT
#
# PollForSourceChanges = false o tren nghia la pipeline KHONG tu hoi.
# Khong co rule nay thi no chi chay khi co nguoi bam tay - va do la
# kieu hong im lang: moi thu deu "thanh cong", chi la khong bao gio
# chay.
########################################

resource "aws_cloudwatch_event_rule" "commit" {
  count = local.enabled && var.source_type == "codecommit" ? 1 : 0

  name        = "${local.name}-commit"
  description = "Chay pipeline vending khi co commit vao ${var.branch_name}"

  event_pattern = jsonencode({
    source      = ["aws.codecommit"]
    detail-type = ["CodeCommit Repository State Change"]
    resources   = ["arn:${data.aws_partition.current.partition}:codecommit:${var.region}:${data.aws_caller_identity.current.account_id}:${var.repository_name}"]
    detail = {
      event         = ["referenceCreated", "referenceUpdated"]
      referenceType = ["branch"]
      referenceName = [var.branch_name]
    }
  })
}

resource "aws_iam_role" "events" {
  count = local.enabled && var.source_type == "codecommit" ? 1 : 0

  name = "${local.name}-events"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "events" {
  count = local.enabled && var.source_type == "codecommit" ? 1 : 0

  name = "kich-hoat"
  role = aws_iam_role.events[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["codepipeline:StartPipelineExecution"]
      Resource = [aws_codepipeline.vending[0].arn]
    }]
  })
}

resource "aws_cloudwatch_event_target" "pipeline" {
  count = local.enabled && var.source_type == "codecommit" ? 1 : 0

  rule     = aws_cloudwatch_event_rule.commit[0].name
  arn      = aws_codepipeline.vending[0].arn
  role_arn = aws_iam_role.events[0].arn
}

########################################
# OUTPUT
########################################

output "pipeline_name" {
  value = local.enabled ? aws_codepipeline.vending[0].name : ""
}

output "pipeline_console_url" {
  value = local.enabled ? format(
    "https://%s.console.aws.amazon.com/codesuite/codepipeline/pipelines/%s/view?region=%s",
    var.region, aws_codepipeline.vending[0].name, var.region,
  ) : ""
}

output "next_steps" {
  value = local.enabled ? local.next_steps : ""
}

output "approval_topic_arn" {
  description = "SNS topic gui thu duyet. Kiem dia chi da xac nhan chua bang list-subscriptions-by-topic."
  value       = local.enabled ? aws_sns_topic.approval[0].arn : ""
}
