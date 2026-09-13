########################################
# AI VAO ACCOUNT NAO - va CHI the
#
# =======================================================================
# CHIEU O DAY NGUOC VOI SCP
#
#   SCP              XOA mot Deny la NOI
#   permission-set   TAO mot assignment la NOI
#
# Mot assignment moi lam ca mot group vao duoc mot account ma truoc do
# khong vao duoc, va no co hieu luc NGAY - Identity Center day thay doi
# xuong moi role da sinh, khong ai phai dang nhap lai.
#
# gate.py biet chieu do (bang LUAT, muc aws_ssoadmin_account_assignment).
# Sao chep luat cua SCP sang day se cho `+ assignment` chay tu do va chan
# viec THU HOI quyen.
#
# =======================================================================
# RANH GIOI: AI vao duoc, KHONG PHAI vao roi lam duoc gi
#
# Pipeline nay sua duoc assignment va thanh vien group. No KHONG sua duoc
# noi dung quyen - managed policy attachment, inline policy, permission
# set. Xem local.tu_choi_dich_vu.
#
# Vi sao chia o day: doi mot managed policy attachment la doi quyen cua
# MOI NGUOI dang dung permission set do, o MOI account, ngay lap tuc. Do
# la mot thay doi co ban kinh bang ca to chuc, va no khong phai viec hang
# ngay - no o layer cha, sua bang tay.
########################################

locals {
  stages = [
    {
      key     = "cloudops-permission-set"
      layer   = "landing-zone/permission-sets"
      enabled = true

      ####################################
      # HAI RESOURCE, KHONG HON
      #
      # Layer permission-sets quan ca permission set, inline policy,
      # managed policy attachment, group va user. -target giu pipeline
      # lai o dung hai thu tra loi cau hoi "ai vao account nao".
      #
      # LUU Y: -target gioi han APPLY. PLAN van refresh TOAN BO state,
      # nen role can doc rong - xem local.quyen_dich_vu.
      #
      # -------------------------------------------------------------
      # VA -target KHONG DONG KIN THEO PHU THUOC
      #
      # `-target=X` nghia la "X VA NHUNG GI X CAN", khong phai "chi X".
      # aws_ssoadmin_account_assignment.this tham chieu
      # aws_ssoadmin_permission_set qua permission_set_arn, ma set thi
      # KHONG nam trong danh sach nay. Nen he ai sua noi dung mot
      # permission set la no bi keo vao ban plan cung con assignment.
      #
      # Luc do gate.py chan, vi bang pham vi cua stage
      # "cloudops-permission-set" chi liet ke assignment va group
      # membership. Do la ket qua DUNG - xem khoi chu thich dau file: doi
      # noi dung mot permission set la doi quyen cua moi nguoi dang dung
      # set do, o moi account, ngay lap tuc.
      #
      # Nen khi gap loi do, cach chua KHONG phai them ten resource vao
      # day, cung khong phai noi bang pham vi cua gate.py. La apply layer
      # cha bang tay, co nguoi doc, roi de pipeline chay lai.
      #
      # Da gap dung tinh huong nay o ops-trail voi bucket log (loi 123).
      ####################################
      targets = [
        "aws_ssoadmin_account_assignment.this",
        "aws_identitystore_group_membership.this",
      ]

      khong_co_lint = "permission-sets chua co catalog - phep kiem y nghia la gate.py, muc aws_ssoadmin_account_assignment va aws_identitystore_group_membership"

      ####################################
      # VI SAO CHUA CO VERIFY
      #
      # Doc lai assignment tu Identity Center thi lam duoc ngay
      # (sso-admin:ListAccountAssignments), va no da duoc do mot lan: buoc
      # -refresh-only cua apply in ra id that cua assignment moi.
      #
      # Nhung phep do CO Y NGHIA thi khac: mot assignment ton tai khong
      # noi rang nguoi trong group do VAO DUOC account. Identity Center
      # con phai sinh role AWSReservedSSO_<set>_<hash> o account dich, va
      # viec do KHONG tuc thi.
      #
      # Doc thu ba do doi mot phien o ACCOUNT KHAC - thu buoc verify
      # khong co, vi no chay bang danh tinh cua CodeBuild o management.
      #
      # Nen mot verify chi doc assignment se luon xanh va khong tra loi
      # duoc cau hoi that. Khai ra thay vi them mot lop kiem de chiu.
      ####################################
      khong_co_verify = "doc lai assignment thi luon xanh nhung khong tra loi duoc cau hoi that: nguoi trong group co vao duoc account khong. Cau do doi mot phien o ACCOUNT DICH, ma buoc verify chay bang danh tinh CodeBuild o management."

      mo_ta = "Ai vao account nao. TAO mot assignment la NOI - chieu nguoc voi SCP."
    },
  ]

  catalogs = []

  khong_co_catalog = "Layer permission-sets khai bang HCL (locals-policies.tf, permission-sets.tf), chua co catalog YAML. Khi catalog hoa thi them vao local.catalogs va XOA dong nay."

  ####################################
  # STATE LAYER NAY DOC CUA LAYER KHAC
  #
  # permission-sets/vending.tf doc state cua account-baseline qua
  # terraform_remote_state de lay danh sach account vua vend - xem
  # local.vending_by_scope.
  #
  # Khong khai o day thi plan CHET voi:
  #   Error: Unable to access object "account-baseline/terraform.tfstate"
  #   ... StatusCode: 403, Forbidden
  # va loi do khong nhac gi toi terraform_remote_state.
  #
  # CHI DOC. Module cap dung s3:GetObject, khong bao gio PutObject.
  ####################################
  state_chi_doc = [
    "account-baseline/terraform.tfstate",
  ]

  ####################################
  # DOC RONG
  #
  # plan refresh TOAN BO state cua layer: permission set, inline policy,
  # managed policy attachment, group, user, membership, assignment. Va
  # layer doc data.aws_organizations_organization, nen can ca
  # organizations:Describe/List.
  ####################################
  quyen_dich_vu = [
    {
      Sid    = "DocIdentityCenter"
      Effect = "Allow"
      Action = [
        "sso:Describe*",
        "sso:List*",
        "sso:Get*",
        "sso-directory:Describe*",
        "sso-directory:List*",
        "sso-directory:Search*",
        "identitystore:Describe*",
        "identitystore:List*",
        "identitystore:Get*",
        "organizations:Describe*",
        "organizations:List*",
        "iam:GetRole",
        "iam:ListRoles",
        "iam:GetSAMLProvider",
      ]
      Resource = "*"
    },

    ####################################
    # GHI HEP - BON ACTION
    #
    # Day la ranh gioi that cua pipeline nay. Bon action, va ca bon deu
    # tra loi cung mot cau hoi: AI vao duoc.
    ####################################
    {
      Sid    = "GhiAiVaoAccountNao"
      Effect = "Allow"
      Action = [
        "sso:CreateAccountAssignment",
        "sso:DeleteAccountAssignment",
        "identitystore:CreateGroupMembership",
        "identitystore:DeleteGroupMembership",
      ]
      Resource = "*"
    },
  ]

  ####################################
  # TU CHOI - VIET RO
  #
  # Vi sao can, khi Allow da hep: Deny THANG Allow, nen mot Deny viet ro
  # van chan duoc ke ca khi mot policy khac gan vao cung role mo rong
  # hon. Va no DOC DUOC - nguoi doc danh sach Allow khong biet duoc thu
  # gi CO Y khong cho.
  ####################################
  tu_choi_dich_vu = [
    {
      Sid    = "KhongSuaNoiDungQuyen"
      Effect = "Deny"
      Action = [
        # Noi dung cua mot permission set: doi mot dong o day la doi
        # quyen cua MOI nguoi dang dung set do, o MOI account, ngay lap
        # tuc. Ban kinh bang ca to chuc.
        "sso:CreatePermissionSet",
        "sso:DeletePermissionSet",
        "sso:UpdatePermissionSet",
        "sso:PutInlinePolicyToPermissionSet",
        "sso:DeleteInlinePolicyFromPermissionSet",
        "sso:AttachManagedPolicyToPermissionSet",
        "sso:DetachManagedPolicyFromPermissionSet",
        "sso:AttachCustomerManagedPolicyReferenceToPermissionSet",
        "sso:DetachCustomerManagedPolicyReferenceFromPermissionSet",
        "sso:PutPermissionsBoundaryToPermissionSet",
        "sso:DeletePermissionsBoundaryFromPermissionSet",

        # Tao/xoa NGUOI va GROUP. Pipeline nay noi ai vao account nao;
        # no khong duoc tao ra "ai" moi.
        "identitystore:CreateUser",
        "identitystore:DeleteUser",
        "identitystore:UpdateUser",
        "identitystore:CreateGroup",
        "identitystore:DeleteGroup",
        "identitystore:UpdateGroup",

        # Xoa ca instance Identity Center.
        "sso:DeleteInstance",
        "sso:DeleteApplication",
      ]
      Resource = "*"
    },
  ]
}

module "pipeline" {
  source = "../../modules/tf-pipeline"

  ten     = "ops-permission-set"
  enable  = var.enable
  project = var.project
  region  = var.region

  stages           = local.stages
  catalogs         = local.catalogs
  khong_co_catalog = local.khong_co_catalog
  state_chi_doc    = local.state_chi_doc
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
