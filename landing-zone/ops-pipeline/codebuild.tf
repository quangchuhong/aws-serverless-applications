########################################
# HAI PROJECT
#
#   terraform   lint + plan + apply cho tung layer ops
#   drift       chay theo lich, CHI plan, khong bao gio apply
#
# Tach hai vi chung khac nhau o dieu quan trong nhat: mot cai co the
# sua ha tang, mot cai khong. Nhoi ca hai vao mot project voi mot bien
# TF_ACTION la cach chac chan de mot ngay nao do bien do bi de len sai.
########################################

locals {
  # Phien ban Terraform GHIM. Khong dung "latest".
  #
  # `terraform apply tfplan` doi dung phien ban da sinh ra tfplan. Neu
  # CodeBuild tai ban moi giua luc plan va luc apply thi apply tu choi
  # file plan - va thong bao noi ve dinh dang file, khong noi rang co
  # ai do vua phat hanh mot ban Terraform.
  terraform_version = "1.9.8"
}

resource "aws_cloudwatch_log_group" "build" {
  count = local.enabled ? 1 : 0

  name              = "/aws/codebuild/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_codebuild_project" "terraform" {
  count = local.enabled ? 1 : 0

  name          = "${local.name}-terraform"
  description   = "lint + plan + apply cho cac layer van hanh. Xem templates/buildspec-terraform.yml"
  service_role  = aws_iam_role.codebuild[0].arn
  build_timeout = var.build_timeout_minutes

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    # Gia tri MAC DINH. Moi action trong pipeline de len nhung cai no
    # can - xem pipeline.tf.
    environment_variable {
      name  = "TF_VERSION"
      value = local.terraform_version
    }
    environment_variable {
      name  = "STATE_BUCKET"
      value = var.state_bucket
    }
    environment_variable {
      name  = "STATE_REGION"
      value = var.region
    }
    environment_variable {
      name  = "STATE_LOCK_TABLE"
      value = var.state_lock_table
    }
    environment_variable {
      name  = "TFVARS_BUCKET"
      value = var.tfvars_bucket
    }

    environment_variable {
      name  = "LAYER_DIR"
      value = "chua-dat"
    }
    environment_variable {
      name  = "STATE_KEY"
      value = "chua-dat"
    }
    environment_variable {
      name  = "TF_ACTION"
      value = "plan"
    }
    environment_variable {
      name  = "TF_TARGETS"
      value = ""
    }
    environment_variable {
      name  = "LINT_CMD"
      value = ""
    }

    # Pipeline nay KHONG co cong duyet, nen day la lop bu: plan co xoa
    # hoac thay the thi dung ngay o buoc plan. Xem main.tf.
    environment_variable {
      name  = "FAIL_ON_DESTROY"
      value = "yes"
    }
    environment_variable {
      name  = "FIRST_APPLY"
      value = "no"
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.build[0].name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/templates/buildspec-terraform.yml")
  }
}

########################################
# PHAT HIEN DRIFT
#
# CHI `terraform plan -lock=false`. Khong co nhanh apply nao trong
# buildspec cua no - khong phai vi mot bien duoc dat dung, ma vi doan
# code apply khong ton tai.
#
# -lock=false: buoc nay chay luc 2 gio sang va co the trung voi mot lan
# apply that. Mot phep KIEM lam chan mot lan SUA la mot phep kiem gay
# ra su co.
#
# Nguon la GITHUB/CodeCommit qua NO_SOURCE? Khong - dung CODEPIPELINE
# thi phai co pipeline. O day dung nguon rieng de chay doc lap theo
# lich, khong phu thuoc pipeline.
########################################

resource "aws_codebuild_project" "drift" {
  count = local.enabled ? 1 : 0

  name          = "${local.name}-drift"
  description   = "Phat hien drift: chi plan, khong bao gio apply"
  service_role  = aws_iam_role.codebuild[0].arn
  build_timeout = var.build_timeout_minutes

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "TF_VERSION"
      value = local.terraform_version
    }
    environment_variable {
      name  = "STATE_BUCKET"
      value = var.state_bucket
    }
    environment_variable {
      name  = "STATE_REGION"
      value = var.region
    }
    environment_variable {
      name  = "STATE_LOCK_TABLE"
      value = var.state_lock_table
    }
    environment_variable {
      name  = "TFVARS_BUCKET"
      value = var.tfvars_bucket
    }
    environment_variable {
      name  = "DRIFT_TOPIC_ARN"
      value = local.drift_topic
    }

    # Danh sach "<duong dan layer>=<khoa state>", cach nhau bang dau
    # cach. Sinh tu cung local.stage_keys ma pipeline dung, nen khong
    # co chuyen drift kiem mot tap layer khac voi tap duoc apply.
    environment_variable {
      name  = "LAYERS"
      value = join(" ", [for l, k in local.stage_keys : "${l}=${k}"])
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.build[0].name
    }
  }

  source {
    type            = var.source_type == "codecommit" ? "CODECOMMIT" : "S3"
    location        = var.source_type == "codecommit" ? "https://git-codecommit.${var.region}.amazonaws.com/v1/repos/${var.repository_name}" : "${var.source_bucket}/${var.source_object_key}"
    git_clone_depth = var.source_type == "codecommit" ? 1 : null
    buildspec       = file("${path.module}/templates/buildspec-drift.yml")
  }

  source_version = var.source_type == "codecommit" ? "refs/heads/${var.branch_name}" : null
}

########################################
# LICH CHAY DRIFT
########################################

resource "aws_cloudwatch_event_rule" "drift" {
  count = local.enabled ? 1 : 0

  name                = "${local.name}-drift"
  description         = "Phat hien drift cac layer van hanh"
  schedule_expression = var.drift_cron
}

resource "aws_cloudwatch_event_target" "drift" {
  count = local.enabled ? 1 : 0

  rule     = aws_cloudwatch_event_rule.drift[0].name
  arn      = aws_codebuild_project.drift[0].arn
  role_arn = aws_iam_role.events[0].arn
}

########################################
# QUYEN DOC REPO CHO PROJECT DRIFT
#
# Project terraform nhan nguon tu CodePipeline nen khong can quyen
# CodeCommit. Project drift thi tu clone, nen can.
########################################

resource "aws_iam_role_policy" "codebuild_source" {
  count = local.enabled && var.source_type == "codecommit" ? 1 : 0

  name = "doc-repo"
  role = aws_iam_role.codebuild[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "codecommit:GitPull",
        "codecommit:GetBranch",
        "codecommit:GetCommit",
        "codecommit:GetRepository",
      ]
      Resource = "arn:${data.aws_partition.current.partition}:codecommit:${var.region}:${data.aws_caller_identity.current.account_id}:${var.repository_name}"
    }]
  })
}
