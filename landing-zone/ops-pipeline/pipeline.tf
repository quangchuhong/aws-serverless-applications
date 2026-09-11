########################################
# PIPELINE
#
# Nguon -> mot stage cho moi layer trong local.stages.
#
# Moi stage co HAI action: Plan roi Apply. Khong co action cho, khong
# co cong duyet - xem main.tf.
#
# Lint KHONG la mot stage rieng: no chay trong CHINH action Plan cua
# tung stage, truoc `terraform plan`. Ly do la lint cua moi layer doc
# state cua layer do (organization/lint.sh --aws doi chieu voi policy
# dang gan that), nen no can dung backend va dung credential ma action
# do da co. Mot stage lint chung o dau pipeline se phai tu cau hinh
# lai bon thu do cho tung layer.
########################################

resource "aws_codepipeline" "ops" {
  count = local.enabled ? 1 : 0

  name     = local.name
  role_arn = aws_iam_role.pipeline[0].arn

  # V2: cho phep bien o cap pipeline va lich chay. Khong dung tinh nang
  # nao cua V2 ngay bay gio, nhung V1 khong nang cap tai cho duoc -
  # doi sau la tao lai ca pipeline.
  pipeline_type = "V2"

  artifact_store {
    location = aws_s3_bucket.artifacts[0].bucket
    type     = "S3"

    encryption_key {
      id   = aws_kms_key.artifacts[0].arn
      type = "KMS"
    }
  }

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
  # MOT STAGE MOI LAYER
  #
  # KHOA MANG SO THU TU - loi 113.
  #
  # Terraform duyet map theo thu tu SAP XEP KHOA, khong theo thu tu
  # phan tu trong danh sach. O vending-pipeline, sau khoa cu (A..F)
  # tinh co sap dung thu tu mong muon, nen khong ai thay rang thu tu
  # stage dang do phep sap chuoi quyet dinh - toi khi mot stage ten
  # "E0" duoc them va no nam SAU "E".
  #
  # format("%02d", i) lam thu tu den tu DANH SACH. %02d chu khong %d:
  # muoi stage thi "10" phai sap sau "9", ma theo chuoi "10" < "9".
  ####################################
  dynamic "stage" {
    for_each = {
      for s in local.stages :
      format("%02d-%s", s.thu_tu, s.key) => s
    }

    content {
      name = replace(stage.value.key, "-", "_")

      action {
        name             = "Plan"
        category         = "Build"
        owner            = "AWS"
        provider         = "CodeBuild"
        version          = "1"
        run_order        = 1
        input_artifacts  = ["nguon"]
        output_artifacts = ["plan_${replace(stage.value.key, "-", "_")}"]

        configuration = {
          ProjectName = aws_codebuild_project.terraform[0].name
          EnvironmentVariables = jsonencode([
            { name = "LAYER_DIR", value = stage.value.layer, type = "PLAINTEXT" },
            { name = "STATE_KEY", value = local.stage_keys[stage.value.layer], type = "PLAINTEXT" },
            { name = "TF_ACTION", value = "plan", type = "PLAINTEXT" },
            { name = "TF_TARGETS", value = join(" ", try(stage.value.targets, [])), type = "PLAINTEXT" },
            { name = "LINT_CMD", value = try(stage.value.lint, ""), type = "PLAINTEXT" },
          ])
        }
      }

      ####################################
      # APPLY DUNG BAN PLAN DA LUU
      #
      # input_artifacts lay tu chinh stage nay, khong phai tu "nguon":
      # apply phai thuc hien DUNG ke hoach ma plan da sinh. Tinh lai
      # mot plan moi o buoc apply nghia la thu duoc kiem khong con la
      # thu duoc thuc hien.
      ####################################
      action {
        name            = "Apply"
        category        = "Build"
        owner           = "AWS"
        provider        = "CodeBuild"
        version         = "1"
        run_order       = 2
        input_artifacts = ["plan_${replace(stage.value.key, "-", "_")}"]

        configuration = {
          ProjectName = aws_codebuild_project.terraform[0].name
          EnvironmentVariables = jsonencode([
            { name = "LAYER_DIR", value = stage.value.layer, type = "PLAINTEXT" },
            { name = "STATE_KEY", value = local.stage_keys[stage.value.layer], type = "PLAINTEXT" },
            { name = "TF_ACTION", value = "apply", type = "PLAINTEXT" },
            { name = "TF_TARGETS", value = join(" ", try(stage.value.targets, [])), type = "PLAINTEXT" },
            # Apply khong chay lai lint: lint da chay o buoc plan, tren
            # cung commit. Chay lai chi lam apply co the that bai vi mot
            # ly do khong lien quan gi toi ban plan da duoc duyet.
            { name = "LINT_CMD", value = "", type = "PLAINTEXT" },
          ])
        }
      }
    }
  }
}

########################################
# KICH HOAT
#
# PollForSourceChanges = false o tren nghia la pipeline KHONG tu hoi.
# Khong co rule nay thi no chi chay khi co nguoi bam tay - va do la
# kieu hong im lang: moi thu deu "thanh cong", chi la khong bao gio
# chay.
#
# KHONG loc theo duong dan, va khong can: mot luot chay toan
# "KHONG CO THAY DOI" la nhanh va gan nhu mien phi. Do la dac tinh cua
# layer catalog-driven. (CodePipeline V2 loc duoc theo file path, nhung
# chi voi nguon CodeConnections - CodeCommit thi khong.)
########################################

resource "aws_cloudwatch_event_rule" "commit" {
  count = local.enabled && var.source_type == "codecommit" ? 1 : 0

  name        = "${local.name}-commit"
  description = "Chay pipeline van hanh khi co commit vao ${var.branch_name}"

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

resource "aws_cloudwatch_event_target" "commit" {
  count = local.enabled && var.source_type == "codecommit" ? 1 : 0

  rule     = aws_cloudwatch_event_rule.commit[0].name
  arn      = aws_codepipeline.ops[0].arn
  role_arn = aws_iam_role.events[0].arn
}
