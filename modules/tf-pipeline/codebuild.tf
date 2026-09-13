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
  #
  # ---------------------------------------------------------------
  # 1.9.8 -> 1.11.3: MOT BUG CUA TERRAFORM, KHONG PHAI MOT LAN NANG CAP
  #
  # 1.9.8 CRASH khi apply mot file plan tao bang -target, o mot layer co
  # bien mang khoi `validation`:
  #
  #   panic: checkable object status report for unexpected checkable
  #          object var.security_hub_standards
  #          ... evalVariableValidations
  #
  # Ba dieu kien do deu la thiet ke cua chinh pipeline nay: -target la
  # ranh gioi ghi, file plan la thu gate.py doc, va moi layer deu co
  # validation. Nen no khong phai mot truong hop bien - no la duong di
  # BINH THUONG cua mot thay doi that.
  #
  # Vi sao no an lau den vay: MOI lan apply xanh tu truoc toi gio deu la
  # no-op (0 added, 0 changed, 0 destroyed). Quy uoc "lan chay dau phai
  # la mot lan khong co thay doi" la mot quy uoc tot, va no da che dung
  # cai duong ma mot thay doi that phai di qua. "Pipeline chay on" khi do
  # chi co nghia la duong ong THONG, chua bao gio co nghia la APPLY DUOC.
  #
  # 1.11.3 khong crash - DO bang mot lan chay that (mot rule Config duoc
  # tao), khong phai doc changelog: toi khong tra ra duoc ban nao vá.
  #
  # Va tu luc do viec nang nay thanh BAT BUOC chu khong con la tuy chon:
  # state cua config-detective da duoc 1.11.3 ghi, nen 1.9.8 tu choi doc.
  #
  # Trung voi phien ban tren may nguoi van hanh. Giu hai ben bang nhau la
  # cach duy nhat de khong ai bi khoa ra khoi state cua chinh minh.
  terraform_version = "1.11.3"
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

    environment_variable {
      name  = "GATE_STAGE"
      value = "chua-dat"
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
# CATALOG - LINT OFFLINE VA BAO CAO HET HAN
#
# Tach khoi project terraform vi no khac o dieu quan trong nhat: no
# KHONG co backend, KHONG co tfvars, KHONG goi AWS, va khong cai
# Terraform. Nen no chay duoc o DAU pipeline, truoc khi bat ky layer nao
# duoc init.
#
# Do la ca ly do ton tai cua no: mot loi schema o catalog cua layer thu
# ba phai dung pipeline TRUOC khi stage dau cham vao AWS - khong phai o
# stage thu ba, sau khi hai stage dau da apply xong.
########################################

resource "aws_codebuild_project" "catalog" {
  # KHONG tao khi khong co catalog nao. Mot project ton tai ma khong stage
  # nao goi la mot thu nguoi doc se tuong dang chay.
  count = local.enabled && local.co_catalog ? 1 : 0

  name          = "${local.name}-catalog"
  description   = "Lint offline moi catalog + bao cao loosen het han. Khong goi AWS."
  service_role  = aws_iam_role.codebuild[0].arn
  build_timeout = 15

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    # Gia tri MAC DINH. Hai action trong pipeline de len nhung cai chung
    # can - xem pipeline.tf.
    environment_variable {
      name  = "MODE"
      value = "lint"
    }
    environment_variable {
      name  = "JOBS"
      value = local.lint_jobs
    }
    environment_variable {
      name  = "CHAN"
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
    buildspec = file("${path.module}/templates/buildspec-catalog.yml")
  }
}

########################################
# VERIFY - DOC LAI AWS SAU KHI APPLY
#
# Tach khoi project terraform vi no khac o ba dieu, va ca ba deu quan
# trong:
#
#   KHONG cai Terraform    nhanh hon ~15 giay moi lan chay
#   KHONG doc state        no hoi AWS, khong hoi Terraform
#   KHONG keo tfvars       khong can biet cau hinh mong doi la gi
#
# Dieu thu hai la ly do chinh. Mot phep verify doc state se tra loi dung
# cau hoi ma state da tra loi roi - va do la cau hoi SAI. Loi 121 va 126
# ca hai deu la truong hop state noi "xong" trong khi AWS chua co tac
# dung gi.
#
# Nen no cung KHONG duoc nhan ASSUME_ROLE_ARN: script goi AWS CLI bang
# danh tinh cua CodeBuild, o account management. Mot stage can doc o
# account khac phai khai khong_co_verify - xem check "moi_stage_co_verify".
########################################

resource "aws_codebuild_project" "verify" {
  # KHONG tao khi khong stage nao co verify. Mot project ton tai ma
  # khong action nao goi la mot thu nguoi doc se tuong dang chay.
  count = local.enabled && local.co_verify ? 1 : 0

  name          = "${local.name}-verify"
  description   = "Doc lai AWS sau khi apply. Khong cai Terraform, khong doc state."
  service_role  = aws_iam_role.codebuild[0].arn
  build_timeout = 15

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    # Gia tri MAC DINH. Moi action verify de len nhung cai no can -
    # xem pipeline.tf.
    environment_variable {
      name  = "LAYER_DIR"
      value = "chua-dat"
    }
    environment_variable {
      name  = "VERIFY_CMD"
      value = ""
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.build[0].name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/templates/buildspec-verify.yml")
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
