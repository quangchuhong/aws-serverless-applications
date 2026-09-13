########################################
# CLOUDTRAIL TO CHUC
#
# =======================================================================
# THU DUY NHAT TRA LOI DUOC "AI DA LAM GI"
#
# Va no khong tra loi duoc VE QUA KHU sau khi bi tat. Mot trail ngung ghi
# luc 2 gio sang va duoc bat lai luc 9 gio khong de lai gi cho bay tieng
# o giua - ke ca sau khi da sua lai.
#
# Nen moi thay doi o day deu la NOI theo gate.py:
#
#   xoa trail                       khong con ban ghi
#   enable_logging = false          trail con do nhung khong ghi gi
#   is_multi_region_trail = false   hoat dong o region khac thanh vo hinh
#   include_global_service_events   mat su kien IAM, STS, CloudFront -
#     = false                       dung nhung thu dung de leo quyen
#   object lock days GIAM           log co the bi xoa som hon
#   versioning != Enabled           ghi de mot file log khong de lai ban cu
#
# gate.py co ca sau (muc aws_cloudtrail, aws_s3_bucket_object_lock_configuration,
# aws_s3_bucket_versioning, aws_s3_bucket_public_access_block).
########################################

locals {
  stages = [
    {
      key     = "cloudops-trail"
      layer   = "landing-zone/org-trail"
      enabled = var.enable_trail_stage

      ####################################
      # KHONG -target VAO BUCKET
      #
      # Bucket log, object lock va lifecycle deu thuoc layer nay, nhung
      # chung KHONG nam trong pham vi pipeline: tao lai mot bucket log la
      # mat toan bo log cu, va do khong phai thu de mot duong tu dong
      # lam duoc.
      #
      # Chi trail. Neu mot ngay nao do can sua object lock thi do la mot
      # lan apply bang tay, co nguoi doc.
      #
      # ---------------------------------------------------------------
      # NHUNG -target KHONG DU DE LAM DIEU DO - DOC TRUOC KHI TIN DONG TREN
      #
      # `-target=X` khong co nghia la "chi X". No co nghia la "X VA
      # NHUNG GI X CAN". aws_cloudtrail.this tham chieu aws_s3_bucket.trail
      # qua s3_bucket_name, nen HE bucket co bat ky sai khac nao la no bi
      # keo vao ban plan cung con trail - ke ca khi khong ai dong toi no.
      #
      # Da do: lan plan that dau tien cua stage nay ra `0 tao, 2 sua`, cai
      # thu hai la aws_s3_bucket.trail[0] voi dung mot tag lech
      # (Environment = "shared" con sot lai tu truoc khi tag policy cam
      # gia tri do). -target van duoc dat dung; no chi khong phai hang rao.
      #
      # Thu THUC SU giu ranh gioi la gate.py: bang pham vi theo stage
      # (muc "cloudops-trail" chi liet ke aws_cloudtrail) doc ban plan da
      # sinh ra va tu choi moi resource ngoai danh sach. Dong nay dung o
      # day de lan sau khong ai di sua -target khi thay gate.py keu.
      #
      # He qua phai chap nhan: MOI sai khac cua bucket - ke ca mot cai
      # tag - deu lam stage nay do, cho toi khi bucket duoc apply bang
      # tay cho khop lai. Do la chieu hong DUNG: mot cong chan nga ve
      # phia chan khi gap thu no khong duoc phep sua.
      ####################################
      targets = [
        "aws_cloudtrail.this",
      ]

      khong_co_lint = "org-trail khong co catalog - phep kiem y nghia la gate.py, muc aws_cloudtrail: sau thuoc tinh don dieu, tat bat ky cai nao cung la NOI"

      ####################################
      # VI SAO CHUA CO VERIFY, VA PHEP DO NAO CAN
      #
      # Phep do dung cho trail KHONG phai "trail co ton tai" - Terraform
      # da biet the. La HAI cau nay:
      #
      #   get-trail-status  IsLogging con true, va LatestDeliveryTime co
      #                     MOI HON luc apply khong
      #   describe-trails   IsOrganizationTrail va IsMultiRegionTrail
      #
      # Cau thu nhat la cau da cuu mot lan: UpdateTrail tra ve 200 xong
      # ma trail ngung ghi thi khong co trieu chung nao, va khoang trong
      # no de lai khong lay lai duoc.
      #
      # Chua viet duoc vi mot ly do do duoc: no can doi ~2 phut sau apply
      # (CloudTrail giao theo lo, khong tuc thi), nen mot buoc verify chay
      # ngay se doc LatestDeliveryTime CU roi ket luan sai theo chieu an
      # tam. Can mot phep cho, va do la thu phai thiet ke chu khong them
      # vao mot dong.
      #
      # Hien lam bang tay - xem next_steps cua layer org-trail muc 2.
      ####################################
      khong_co_verify = "can doi ~2 phut cho CloudTrail giao lo dau tien; mot verify chay ngay se doc LatestDeliveryTime CU va ket luan sai theo chieu an tam. Lam bang tay theo next_steps muc 2 cua org-trail."

      mo_ta = "CloudTrail to chuc. Tat log, bo multi-region, hay bo global service events deu la NOI."
    },
  ]

  catalogs = []

  khong_co_catalog = "org-trail khai bang bien trong tfvars, chua co catalog YAML. Layer nay gan nhu khong doi nen catalog hoa no co the khong dang - nhung dong nay phai o day de viec khong co catalog la mot LUA CHON, khong phai mot cho bi quen."

  quyen_dich_vu = [
    {
      Sid      = "AssumeVaoLogArchive"
      Effect   = "Allow"
      Action   = ["sts:AssumeRole"]
      Resource = var.trail_pipeline_role_arns
    },
    {
      Sid    = "DocTrailOManagement"
      Effect = "Allow"
      Action = [
        "cloudtrail:Describe*",
        "cloudtrail:Get*",
        "cloudtrail:List*",
        "organizations:Describe*",
        "organizations:List*",
      ]
      Resource = "*"
    },
    {
      Sid    = "GhiTrail"
      Effect = "Allow"
      Action = [
        "cloudtrail:UpdateTrail",
        "cloudtrail:StartLogging",
        "cloudtrail:PutEventSelectors",
        "cloudtrail:AddTags",
        "cloudtrail:RemoveTags",
      ]
      Resource = "*"
    },
  ]

  ####################################
  # PHAM VI THAT CUA KHOI DENY NAY - DOC TRUOC KHI TIN NO
  #
  # Deny duoi day gan vao role CodeBuild o ACCOUNT MANAGEMENT. Sau
  # `sts:AssumeRole`, phien moi mang quyen cua ROLE DICH, va policy cua
  # danh tinh goi KHONG di theo.
  #
  # Nen no CHI rang buoc nhung goi API layer nay thuc hien TRUC TIEP bang
  # danh tinh cua CodeBuild, tuc trong account management. Voi nhung
  # resource nam o account khac - qua provider alias co assume_role - no
  # KHONG co tac dung.
  #
  # Va role dich hien tai la OrganizationAccountAccessRole: FULL ADMIN
  # trong account do. Day la QUYET DINH TAM THOI da duoc thong qua - cho
  # cac pipeline chay on roi thu hep sau - khong phai mot cho bo sot.
  #
  # CACH CHUA, khi den luc: `assume_role` cua provider AWS nhan mot
  # SESSION POLICY (truong `policy`). Session policy giao voi quyen cua
  # role dich, nen Deny dat o do rang buoc dung phien dang lam viec. Do
  # la cho DUY NHAT mot Deny co tac dung cho cong viec lien account.
  #
  # GIU khoi nay chu khong xoa: no van co tac dung cho phan chay trong
  # account management, va no ghi lai Y DINH - danh sach nay la ban thao
  # cua session policy tuong lai.
  ####################################
  tu_choi_dich_vu = [
    {
      Sid    = "KhongXoaVaKhongNgungGhi"
      Effect = "Deny"
      Action = [
        # StopLogging la dong nguy hiem nhat trong ca file nay: no khong
        # xoa gi, khong doi gi trong console ngoai mot chu, va no lam moi
        # cau hoi "ai da lam gi" tu luc do tro thanh khong tra loi duoc.
        "cloudtrail:StopLogging",
        "cloudtrail:DeleteTrail",

        # Bucket log: tao lai la mat toan bo log cu.
        "s3:DeleteBucket",
        "s3:PutBucketVersioning",
        "s3:PutObjectLockConfiguration",
        "s3:PutBucketPublicAccessBlock",
      ]
      Resource = "*"
    },
  ]
}

########################################
# BAT STAGE THI PHAI CO ROLE - DANH SACH RONG LA MOT CAI BAY
#
# trail_pipeline_role_arns nuoi truong Resource cua statement
# sts:AssumeRole. Danh sach RONG lam Resource thanh [], va IAM tu choi CA
# POLICY voi mot loi ve dinh dang ARN - khong nhac gi toi bien nao.
#
# Va no khong hien ra o plan: plan van xanh, resource van duoc mo ta day
# du. Loi chi den luc APPLY, o buoc tao aws_iam_role_policy.
#
# Cach doc nhanh mot ban plan xem co dinh bay nay khong:
#   grep -c "OrganizationAccountAccessRole" <file plan>
# Ra 0 nghia la khong co ARN nao - stage se khong assume duoc sang
# account LOG-ARCHIVE.
########################################
check "bat_stage_thi_co_role" {
  assert {
    condition     = !var.enable || !var.enable_trail_stage || length(var.trail_pipeline_role_arns) > 0
    error_message = join(" ", [
      "Stage dang duoc bat nhung trail_pipeline_role_arns RONG.",
      "Statement sts:AssumeRole se co Resource = [], va IAM tu choi ca policy",
      "voi mot loi ve dinh dang ARN khong nhac toi bien nao. Dien ARN role o",
      "account LOG-ARCHIVE, hoac tat stage.",
    ])
  }
}

module "pipeline" {
  source = "../../modules/tf-pipeline"

  ten     = "ops-trail"
  enable  = var.enable
  project = var.project
  region  = var.region

  stages           = local.stages
  catalogs         = local.catalogs
  khong_co_catalog = local.khong_co_catalog
  quyen_dich_vu    = local.quyen_dich_vu
  tu_choi_dich_vu  = local.tu_choi_dich_vu

  source_type       = var.source_type
  repository_name   = var.repository_name
  branch_name       = var.branch_name
  tu_kich_hoat      = var.tu_kich_hoat
  source_bucket     = var.source_bucket
  source_object_key = var.source_object_key

  state_bucket     = var.state_bucket
  state_lock_table = var.state_lock_table
  layer_keys       = var.layer_keys
  tfvars_bucket    = var.tfvars_bucket

  approve_stages  = var.approve_stages
  approval_emails = var.approval_emails

  drift_cron      = var.drift_cron
  drift_emails    = var.drift_emails
  drift_topic_arn = var.drift_topic_arn

  expiry_blocks_pipeline = var.expiry_blocks_pipeline
  build_timeout_minutes  = var.build_timeout_minutes
  log_retention_days     = var.log_retention_days
}
