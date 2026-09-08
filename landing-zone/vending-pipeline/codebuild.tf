########################################
# HAI PROJECT CHO SAU STAGE
#
# Khong phai mot project moi stage. Stage khac nhau o BA gia tri -
# thu muc layer, khoa state, va co assume role hay khong - va
# CodePipeline de len duoc bien moi truong o tung action.
#
# Mot project thi mot lan sua la sua cho tat ca. Sau project thi mot
# ngay nao do chung se lech nhau, va lech o buoc chuan bi backend
# nghia la mot stage apply len mot state khac.
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
  description   = "plan va apply cho cac layer cua vending. Xem templates/buildspec-terraform.yml"
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

    # Kho terraform.tfvars. Giong nhau o moi stage, nen dat o day chu
    # khong de len o tung action - khoa duoc suy ra tu LAYER_DIR.
    environment_variable {
      name  = "TFVARS_BUCKET"
      value = aws_s3_bucket.tfvars[0].bucket
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
      name  = "ASSUME_ROLE_ARN"
      value = ""
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
# CHO ATTACHMENT - chi ton tai khi co stage network
########################################

resource "aws_codebuild_project" "cho_attachment" {
  count = local.enabled && local.network_on ? 1 : 0

  name          = "${local.name}-cho-attachment"
  description   = "Cho TGW attachment sang available truoc stage D"
  service_role  = aws_iam_role.codebuild[0].arn
  build_timeout = var.wait_attachment_minutes + 5

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "ASSUME_ROLE_ARN"
      value = var.network_deploy_role_arn
    }
    environment_variable {
      name  = "WAIT_MINUTES"
      value = tostring(var.wait_attachment_minutes)
    }

    # TGW_ID de len o pipeline.tf neu ban biet truoc. De trong thi
    # stage nay khong loc duoc theo TGW nao va se dung lai - co y:
    # cho "moi attachment trong account" la mot dieu kien khac han,
    # va no se dung cho ca nhung attachment khong lien quan.
    environment_variable {
      name  = "TGW_ID"
      value = var.transit_gateway_id
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.build[0].name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/templates/buildspec-cho-attachment.yml")
  }
}

variable "transit_gateway_id" {
  description = <<-EOT
    TGW ma stage cho se hoi trang thai attachment.

      cd ../network && terraform output -raw transit_gateway_id

    DE RONG thi stage cho dung lai voi mot loi ro rang, thay vi cho
    tren MOI attachment cua account - trong do co nhung cai khong
    lien quan gi toi lan chay nay.
  EOT
  type        = string
  default     = ""
}

check "co_tgw_id_cho_stage_cho" {
  assert {
    condition     = !local.enabled || !local.network_on || var.transit_gateway_id != ""
    error_message = "network_deploy_role_arn da khai nhung transit_gateway_id de rong - stage cho attachment se khong biet hoi ve TGW nao. Lay: cd ../network && terraform output -raw transit_gateway_id"
  }
}

########################################
# LINT - project rieng
#
# Tach khoi project terraform vi no khong dung chung mot buildspec:
# lint chay ba viec tren CA cay va khong cham vao state. Nhoi no vao
# cung mot buildspec bang mot nhanh `if` thu ba la cach chac chan de
# mot ngay nao do "lint" roi nham vao nhanh apply.
########################################

resource "aws_codebuild_project" "lint" {
  count = local.enabled ? 1 : 0

  name          = "${local.name}-lint"
  description   = "lint.sh + terraform fmt + validate. Khong goi AWS."
  service_role  = aws_iam_role.codebuild[0].arn
  build_timeout = 20

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "TF_VERSION"
      value = local.terraform_version
    }
    environment_variable {
      name  = "LAYERS"
      value = join(" ", distinct([for s in local.stages_all : s.layer]))
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.build[0].name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/templates/buildspec-lint.yml")
  }
}
