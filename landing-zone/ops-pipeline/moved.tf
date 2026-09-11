########################################
# CHUYEN DIA CHI VAO MODULE - 30 RESOURCE
#
# Tach module doi DIA CHI cua moi resource:
#
#   aws_codepipeline.ops  ->  module.pipeline.aws_codepipeline.ops
#
# KHONG co nhung khoi duoi day thi Terraform doc do la "mot resource bien
# mat, mot resource moi xuat hien" va apply se XOA ROI TAO LAI ca 30
# resource - gom KMS key (co cua so cho xoa 7-30 ngay, nen tao lai la mot
# key MOI va key cu nam lai cho xoa) va bucket artifact.
#
# =======================================================================
# PHEP KIEM, VA NO CHI CO MOT KET QUA DUNG
#
#   terraform plan   ->  0 to add, 0 to change, 0 to destroy
#
# Bat ky con so khac 0 nao la mot `moved` bi thieu. KHONG apply khi thay
# so khac - doc dong "will be destroyed" de biet dia chi nao chua co khoi.
#
# Terraform in ca danh sach chuyen o dau ban plan, va so dong do phai la
# 30. It hon nghia la mot khoi khong khop dia chi nao - va Terraform
# KHONG bao loi cho viec do, no chi bo qua.
#
# =======================================================================
# `moved` KHONG GIUP GI CHO VIEC DOI TEN
#
# Ten pipeline, ten bucket, ten role deu chua local.name = "<project>-ops".
# Doi `ten` truyen vao module la doi TEN THAT o AWS, va ten la thuoc tinh
# khong sua tai cho duoc - Terraform se xoa roi tao lai. `moved` chi
# chuyen DIA CHI TRONG STATE, no khong doi duoc gi o AWS.
#
# Do la ly do caller nay truyen ten = "ops", giu nguyen ten cu.
#
# =======================================================================
# SAU KHI PLAN DA SACH: XOA FILE NAY DUOC KHONG
#
# Duoc, sau khi apply. `moved` da hoan tat thi no thanh khong-lam-gi.
# Nhung giu lai cung khong ton gi, va no la tai lieu cho lan sau ai do
# hoi "vi sao dia chi lai co module. o giua".
########################################

moved {
  from = aws_cloudwatch_event_rule.commit
  to   = module.pipeline.aws_cloudwatch_event_rule.commit
}

moved {
  from = aws_cloudwatch_event_rule.drift
  to   = module.pipeline.aws_cloudwatch_event_rule.drift
}

moved {
  from = aws_cloudwatch_event_target.commit
  to   = module.pipeline.aws_cloudwatch_event_target.commit
}

moved {
  from = aws_cloudwatch_event_target.drift
  to   = module.pipeline.aws_cloudwatch_event_target.drift
}

moved {
  from = aws_cloudwatch_log_group.build
  to   = module.pipeline.aws_cloudwatch_log_group.build
}

moved {
  from = aws_codebuild_project.catalog
  to   = module.pipeline.aws_codebuild_project.catalog
}

moved {
  from = aws_codebuild_project.drift
  to   = module.pipeline.aws_codebuild_project.drift
}

moved {
  from = aws_codebuild_project.terraform
  to   = module.pipeline.aws_codebuild_project.terraform
}

moved {
  from = aws_codepipeline.ops
  to   = module.pipeline.aws_codepipeline.ops
}

moved {
  from = aws_iam_role.codebuild
  to   = module.pipeline.aws_iam_role.codebuild
}

moved {
  from = aws_iam_role.events
  to   = module.pipeline.aws_iam_role.events
}

moved {
  from = aws_iam_role.pipeline
  to   = module.pipeline.aws_iam_role.pipeline
}

moved {
  from = aws_iam_role_policy.codebuild
  to   = module.pipeline.aws_iam_role_policy.codebuild
}

moved {
  from = aws_iam_role_policy.codebuild_artifacts
  to   = module.pipeline.aws_iam_role_policy.codebuild_artifacts
}

moved {
  from = aws_iam_role_policy.codebuild_source
  to   = module.pipeline.aws_iam_role_policy.codebuild_source
}

moved {
  from = aws_iam_role_policy.events
  to   = module.pipeline.aws_iam_role_policy.events
}

moved {
  from = aws_iam_role_policy.pipeline
  to   = module.pipeline.aws_iam_role_policy.pipeline
}

moved {
  from = aws_kms_alias.artifacts
  to   = module.pipeline.aws_kms_alias.artifacts
}

moved {
  from = aws_kms_key.artifacts
  to   = module.pipeline.aws_kms_key.artifacts
}

moved {
  from = aws_s3_bucket.artifacts
  to   = module.pipeline.aws_s3_bucket.artifacts
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.artifacts
  to   = module.pipeline.aws_s3_bucket_lifecycle_configuration.artifacts
}

moved {
  from = aws_s3_bucket_policy.artifacts
  to   = module.pipeline.aws_s3_bucket_policy.artifacts
}

moved {
  from = aws_s3_bucket_public_access_block.artifacts
  to   = module.pipeline.aws_s3_bucket_public_access_block.artifacts
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.artifacts
  to   = module.pipeline.aws_s3_bucket_server_side_encryption_configuration.artifacts
}

moved {
  from = aws_s3_bucket_versioning.artifacts
  to   = module.pipeline.aws_s3_bucket_versioning.artifacts
}

moved {
  from = aws_sns_topic.approval
  to   = module.pipeline.aws_sns_topic.approval
}

moved {
  from = aws_sns_topic.drift
  to   = module.pipeline.aws_sns_topic.drift
}

moved {
  from = aws_sns_topic_policy.approval
  to   = module.pipeline.aws_sns_topic_policy.approval
}

moved {
  from = aws_sns_topic_subscription.approval
  to   = module.pipeline.aws_sns_topic_subscription.approval
}

moved {
  from = aws_sns_topic_subscription.drift
  to   = module.pipeline.aws_sns_topic_subscription.drift
}
