########################################
# PIPELINE
#
# Nguon -> mot stage cho moi layer trong local.stages.
#
# Moi stage co HAI hoac BA action:
#
#   Plan 1  ->  Apply 2                 stage khong trong approve_stages
#   Plan 1  ->  Duyet 2  ->  Apply 3    stage trong approve_stages
#
# Roi MOT stage Verify o cuoi, neu var.verify khac rong: no doc lai AWS
# sau khi moi stage da apply xong. Mot stage cho ca pipeline, khong phai
# mot action moi stage - xem khoi chu thich cua no o duoi.
#
# run_order do local.stages tinh (ro_duyet / ro_apply), khong tinh o day:
# hai cho tinh doc lap la hai cho de lech, va mot run_order lech KHONG
# gay loi - no chi lam Apply chay SONG SONG voi cong duyet, tuc apply
# xong truoc khi co nguoi bam.
#
# HAI LINT, HAI CHO
#
# Khoi chu thich nay truoc day ghi rang lint "KHONG the la mot stage
# rieng", va ly do neu ra la: lint doc state cua layer do nen no can
# backend va credential ma action Plan da co.
#
# Ly do do dung - nhung chi cho `--aws`. Va no da lam bo mat mot thu:
#
#   Lint (offline)   stage RIENG o dau pipeline. Schema, sid trung, do
#                    dai 5120, tu khoa chinh minh. Khong can AWS, khong
#                    can state, khong can credential.
#   Lint (--aws)     giu nguyen cho cu, trong action Plan cua tung
#                    stage. No doi chieu voi policy DANG GAN THAT nen no
#                    phai o noi co backend cua layer.
#
# Vi sao phai tach cai thu nhat ra: mot loi schema o catalog cua layer
# THU BA se dung pipeline o stage thu ba - nghia la sau khi hai stage
# dau DA APPLY. Mot loi doc duoc ma khong can AWS thi khong co ly do gi
# de no duoc phat hien sau mot lan apply.
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
  # LINT - MOI CATALOG, KHONG GOI AWS
  #
  # Dung TRUOC moi layer. Mot loi schema o day nghia la khong stage nao
  # phia sau duoc chay, tuc khong co gi o AWS bi cham.
  ####################################
  ####################################
  # KHONG CO CATALOG THI KHONG CO STAGE NAY
  #
  # Hai viec khac nhau, va cho nay de lan:
  #
  #   stage khong ton tai          khong ai doi no bao gi
  #   stage ton tai, khong lam gi  LUON xanh, va cai xanh do duoc doc
  #                                thanh "moi catalog deu sach"
  #
  # var.khong_co_catalog bat nguoi khai phai noi ro ly do - xem check
  # "co_catalog_de_lint".
  ####################################
  dynamic "stage" {
    for_each = local.co_catalog ? [1] : []

    content {
      name = "Lint"

      action {
        name            = "Lint"
        category        = "Build"
        owner           = "AWS"
        provider        = "CodeBuild"
        version         = "1"
        run_order       = 1
        input_artifacts = ["nguon"]

        configuration = {
          ProjectName = aws_codebuild_project.catalog[0].name
          EnvironmentVariables = jsonencode([
            { name = "MODE", value = "lint", type = "PLAINTEXT" },
            { name = "JOBS", value = local.lint_jobs, type = "PLAINTEXT" },
            { name = "CHAN", value = "yes", type = "PLAINTEXT" },
          ])
        }
      }
    }
  }

  ####################################
  # EXPIRY - BAO CAO KHOI `loosen` HET HAN
  #
  # Mac dinh KHONG chan (xem var.expiry_blocks_pipeline). Mot stage
  # khong bao gio that bai la mot stage khong ai doc ket qua, nen mo ta
  # cua bien do noi ro: de false thi phep thi hanh THAT nam o job drift
  # hang dem, va phai co nguoi doc bao dong cua no.
  ####################################
  dynamic "stage" {
    for_each = local.expiry_jobs == "" ? [] : [1]

    content {
      name = "Expiry"

      action {
        name            = "Expiry"
        category        = "Build"
        owner           = "AWS"
        provider        = "CodeBuild"
        version         = "1"
        run_order       = 1
        input_artifacts = ["nguon"]

        configuration = {
          ProjectName = aws_codebuild_project.catalog[0].name
          EnvironmentVariables = jsonencode([
            { name = "MODE", value = "expiry", type = "PLAINTEXT" },
            { name = "JOBS", value = local.expiry_jobs, type = "PLAINTEXT" },
            { name = "CHAN", value = var.expiry_blocks_pipeline ? "yes" : "no", type = "PLAINTEXT" },
          ])
        }
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
            # Khoa de gate.py tra bang PHAM_VI. Dung CHINH key cua stage
            # nen khong co ban sao thu hai de lech.
            { name = "GATE_STAGE", value = stage.value.key, type = "PLAINTEXT" },

            ####################################
            # ROLE SANG ACCOUNT KHAC
            #
            # Rong = layer chay bang credential cua CodeBuild, tuc ngay
            # trong account management. Co gia tri = layer tu assume
            # trong provider block cua no (var.assume_role_arn).
            #
            # Co o CA Plan va Apply. Thieu o Plan thi plan doc account
            # SAI roi bao "tao moi toan bo"; thieu o Apply thi apply
            # TAO THAT o account sai.
            ####################################
            { name = "ASSUME_ROLE_ARN", value = try(stage.value.assume_role_arn, ""), type = "PLAINTEXT" },
          ])
        }
      }

      ####################################
      # CONG DUYET - CHI STAGE TRONG var.approve_stages
      #
      # KHONG co input_artifacts: manual approval khong doc duoc file.
      # Nguoi duyet phai mo log CodeBuild de xem ban plan va ket qua cua
      # lint/gate. Do la mot buoc them, va no co chu dich - mot cong duyet
      # ma noi dung hien ngay canh nut bam se bi bam ma khong doc.
      #
      # ExternalEntityLink tro toi console cua pipeline, khong tro toi log:
      # CodePipeline khong biet truoc id cua lan build, nen mot lien ket
      # "toi log" chi dung duoc o mot lan chay va sai o moi lan sau.
      ####################################
      dynamic "action" {
        for_each = stage.value.co_duyet ? [1] : []

        content {
          name      = "Duyet"
          category  = "Approval"
          owner     = "AWS"
          provider  = "Manual"
          version   = "1"
          run_order = stage.value.ro_duyet

          configuration = {
            NotificationArn = aws_sns_topic.approval[0].arn
            CustomData = join(" ", [
              "${stage.value.key}:",
              stage.value.mo_ta,
              "-- DOC LOG CodeBuild truoc khi duyet: tim dong 'Doi chieu AWS',",
              "'tom tat: N tao, N sua, N xoa' va ket qua cua gate.py.",
            ])
            ExternalEntityLink = "https://${var.region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${local.name}/view?region=${var.region}"
          }
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
        run_order       = stage.value.ro_apply
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
            { name = "ASSUME_ROLE_ARN", value = try(stage.value.assume_role_arn, ""), type = "PLAINTEXT" },
          ])
        }
      }
    }
  }

  ####################################
  # VERIFY - MOT STAGE CUOI, SAU KHI MOI STAGE DA APPLY
  #
  # MOT stage cho ca pipeline, khong phai mot action moi stage. Cac stage
  # cua mot pipeline deu cham vao cung mot mien (organization, hay mang,
  # hay Identity Center), nen mot script doc lai mien do la du - mot lenh
  # moi stage chi lam ba lan goi cung mot script.
  #
  # Va dat o CUOI co mot ly do nua: cac stage chay tuan tu tren cung mot
  # state, nen doc lai giua duong se doc mot trang thai chua xong. Voi
  # layer organization thi stage sec-ou doi cay OU va sec-scp gan lai
  # attachment - hoi "SCP gan vao dau" ngay sau sec-ou la hoi giua luc.
  #
  # input_artifacts la "nguon", KHONG phai ban plan: verify khong doc ke
  # hoach, no doc THUC TE. Lay ban plan vao day se moi no so sanh hai thu
  # vua duoc sinh ra tu cung mot cho.
  #
  # KHONG truyen ASSUME_ROLE_ARN: script goi AWS CLI bang danh tinh cua
  # CodeBuild, o account management.
  ####################################
  dynamic "stage" {
    for_each = var.verify != "" ? [1] : []

    content {
      name = "Verify"

      action {
        name            = "Verify"
        category        = "Build"
        owner           = "AWS"
        provider        = "CodeBuild"
        version         = "1"
        run_order       = 1
        input_artifacts = ["nguon"]

        configuration = {
          ProjectName = aws_codebuild_project.verify[0].name
        }
      }
    }
  }

  ####################################
  # TAO SAU KHI QUYEN DA GAN - KHONG PHAI CHO GON
  #
  # CodePipeline TU CHAY MOT LAN ngay khi duoc tao. Va
  # aws_iam_role_policy.pipeline voi aws_codepipeline cung phu thuoc vao
  # aws_iam_role.pipeline nhung KHONG phu thuoc vao nhau - nen Terraform
  # duoc phep tao pipeline truoc khi gan policy.
  #
  # Ket qua: lan chay dau tien cua MOI pipeline moi dung deu do, voi
  #
  #   The service role or action role doesn't have the permissions
  #   required to access the AWS CodeCommit repository named ...
  #   not authorized to perform: codecommit:GetBranch
  #
  # Da do: pipeline tao luc 17:45:03 UTC, lan chay do bat dau 17:45:04.
  #
  # Thong bao do doc y het mot loi cau hinh that, nen nguoi ta se di tim
  # o cho sai - va o day thi policy VAN DUNG, chi la no chua kip gan.
  # Mot lan chay do khong co that trong mot he thong ma "do" phai co
  # nghia la co chuyen.
  ####################################
  depends_on = [
    aws_iam_role_policy.pipeline,
    aws_s3_bucket_policy.artifacts,
  ]
}

########################################
# KICH HOAT
#
# PollForSourceChanges = false o tren nghia la pipeline KHONG tu hoi.
# Khong co duong kich hoat nao thi no chi chay khi co nguoi bam tay - va
# do la kieu hong im lang: moi thu deu "thanh cong", chi la khong bao gio
# chay.
#
# ---------------------------------------------------------------
# RULE NAY KHONG LOC DUOC THEO DUONG DAN
#
# Khong phai chua ai viet luat do - la khong the viet. Su kien
# "CodeCommit Repository State Change" chi mang repositoryName, commitId,
# oldCommitId, referenceName. Danh sach file khong co trong su kien.
# (CodePipeline V2 loc duoc theo file path, nhung chi voi nguon
# CodeConnections - CodeCommit thi khong.)
#
# Truoc day day duoc coi la chap nhan duoc: mot luot chay toan "KHONG CO
# THAY DOI" la nhanh va gan nhu mien phi. Dieu do dung cho pipeline van
# hanh, nhung KHONG dung cho pipeline vending - no dung bay stage vending
# account, va no chay ca khi chi co mot dong trong docs/ doi.
#
# ---------------------------------------------------------------
# DUONG THU HAI: landing-zone/trigger-filter
#
# Mot ham Lambda dung giua su kien va pipeline: no co hai commit id, goi
# GetDifferences, roi khoi dong dung nhung pipeline co duong dan bi cham.
#
# Khi layer do BAT thi dat tu_kich_hoat = false o day. Hai duong cung no
# se lam bo loc thanh vo nghia (pipeline van chay voi moi push, chi la
# chay hai lan).
########################################

resource "aws_cloudwatch_event_rule" "commit" {
  count = local.kich_hoat_rieng ? 1 : 0

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
  count = local.kich_hoat_rieng ? 1 : 0

  rule     = aws_cloudwatch_event_rule.commit[0].name
  arn      = aws_codepipeline.ops[0].arn
  role_arn = aws_iam_role.events[0].arn
}
