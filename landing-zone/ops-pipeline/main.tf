########################################
# PIPELINE VAN HANH CUA SEC - layer organization
#
# Chay o ACCOUNT MANAGEMENT.
#
# Ha tang cua pipeline nam o ../../modules/tf-pipeline. File nay chi
# KHAI BAO ba thu, va ca ba deu la thu chi dung cho pipeline nay:
#
#   local.stages          stage nao, theo thu tu nao, gioi han vao gi
#   local.catalogs        catalog nao duoc lint offline o stage dau
#   local.quyen_*         RANH GIOI GHI cua role CodeBuild
#
# Ba thu do nam canh nhau co chu dich: mot nguoi review chi can doc mot
# file de tra loi "pipeline nay cham duoc vao gi".
#
# =======================================================================
# CAC LAYER DA TACH STATE TU DAU - KHONG CAN LAYER `<layer>/ops` MOI
#
# Moi layer trong landing-zone/ da co khoa state rieng (xem
# tf-backend/outputs.tf, local.layers). Nen de "van hanh" mot layer thi
# KHONG can dung mot layer con moi - chi can mot stage tro vao no, kem
# -target gioi han pham vi.
#
# Dung khuon dang dung cho organization: SCP, OU va tag policy nam cung
# MOT state, tach nhau bang -target va bang bang PHAM_VI trong
# ops-gate/gate.py.
#
# Ngoai le duy nhat la network/ops - no da la mot layer con that tu
# truoc, vi mot ly do khac: no doc layer cha qua terraform_remote_state.
#
# =======================================================================
# SEC KHONG VAN HANH - SEC DUYET
#
# Pipeline nay thuoc sec ve NOI DUNG (SCP, OU, tag policy la guardrail),
# nhung sec khong bam apply. Sec doc, o hai cho:
#
#   review code   PR tren CodeCommit - doc duoc Y DINH.
#                 Co che: ../codecommit-guard/ (dang TAT).
#   approval      stage trong var.approve_stages - doc duoc BAN PLAN.
#
# Hom nay codecommit-guard tat, nen cong duyet la cho DUY NHAT mot nguoi
# doc thay doi SCP truoc khi no den AWS.
########################################

locals {
  stages = [
    ####################################
    # OU - TRUOC SCP, VA THU TU DO CO LY DO DO DUOC
    #
    # Khoa cua aws_organizations_policy_attachment.scp la
    # "<policy>|<TEN OU>" (xem local.ou_ids). Doi TEN mot OU khong doi id
    # cua no o AWS, nhung doi KHOA trong Terraform - nen Terraform thay
    # mot destroy + create tren cung mot OU id. Khong doi gi o AWS, va
    # van la destroy, nen FAIL_ON_DESTROY se chan.
    #
    # Chan la dung. Dieu quan trong la chan trong CUNG mot luot:
    #
    #   OU truoc SCP   OU doi -> stage SCP ngay sau thay attachment phai
    #                  thay the -> dung lai, co nguoi doc
    #   SCP truoc OU   OU doi xong, khong co gi doi chieu lai attachment
    #                  cho toi luot SAU. State va cau hinh lech nhau
    #                  trong im lang suot khoang giua.
    #
    # GIU NGUYEN CODE TF CUA OU: khong catalog hoa, khong tach state.
    # Stage nay chi -target vao resource da co.
    ####################################
    {
      key     = "sec-ou"
      layer   = "landing-zone/organization"
      enabled = var.enable_ou_stage

      targets = [
        "aws_organizations_organizational_unit.level1",
        "aws_organizations_organizational_unit.level2",
      ]

      # KHONG co catalog nen khong co lint offline. Phep kiem y nghia cho
      # stage nay la gate.py: no biet xoa mot OU la NOI (account roi ve
      # root, moi SCP gan vao OU do het ap dung) va doi parent_id la NOI.
      khong_co_lint = "OU khong co catalog - phep kiem y nghia la gate.py, xem bang LUAT muc aws_organizations_organizational_unit"

      mo_ta = "Cay OU. Xoa mot OU hoac doi parent_id la NOI."
    },

    {
      key     = "sec-scp"
      layer   = "landing-zone/organization"
      enabled = true

      ####################################
      # GIOI HAN VAO DUNG SCP
      #
      # Layer organization quan CA cay OU, delegated administrator va
      # tag policy. Pipeline nay KHONG duoc cham vao chung:
      #
      #   - Cay OU doi vai lan mot nam, va moi lan doi lam moi target
      #     cua SCP phai giai lai. Mot pipeline tu apply viec do la mot
      #     pipeline co the lam ca to chuc khong con SCP nao.
      #   - Delegated administrator la quyen, khong phai cau hinh.
      #
      # -target giu pham vi lai dung hai resource. LUU Y: -target gioi
      # han APPLY, con PLAN van refresh toan bo state - nen role can
      # DOC RONG va GHI HEP. Xem iam.tf.
      ####################################
      targets = [
        "aws_organizations_policy.scp",
        "aws_organizations_policy_attachment.scp",
      ]

      # Lenh lint chay TRUOC plan, trong cung thu muc layer.
      # --aws de bo phan loai THAT/NOI doc duoc policy dang gan that.
      # --strict de canh bao thanh loi trong pipeline.
      #
      # KHONG truyen PROJECT=... o day, du lam vay se "sua" duoc loi
      # 116. lint.sh tu doc ten project tu terraform.tfvars cua layer -
      # dung file ma buildspec vua keo ve. Mot ban sao thu hai cua ten
      # do o day la mot cho de no lech, va mot ten project lech KHONG
      # gay loi: no lam moi policy trong nhu policy moi, tuc moi thay
      # doi trong nhu THAT, tuc lint bao sach ma khong so voi gi.
      lint = "./lint.sh --aws --strict"

      mo_ta = "SCP tu catalog/scp.yaml. That chay tu do, noi phai co khoi loosen."
    },

    ####################################
    # TAG POLICY - CUNG LAYER, CUNG STATE, PHAM VI KHAC
    #
    # aws_organizations_policy.tag CUNG TYPE voi
    # aws_organizations_policy.scp. Nen bang PHAM_VI trong gate.py phai
    # khop theo DIA CHI cho hai stage nay, khong khop theo type - neu
    # khop theo type thi stage nay duoc phep sua SCP va nguoc lai, tuc
    # dung cai ma pham vi ton tai de chan.
    #
    # MAC DINH TAT vi mot ly do do duoc, khong phai vi than trong:
    # tag_policy.enabled = false o layer, nen hai resource nay dang co 0
    # instance. Mot stage cho resource khong ton tai se ra
    # "KHONG CO THAY DOI" mai mai - va mot stage luon xanh ma khong kiem
    # gi la kieu hong im lang.
    ####################################
    {
      key     = "sec-tagging"
      layer   = "landing-zone/organization"
      enabled = var.enable_tagging_stage

      targets = [
        "aws_organizations_policy.tag",
        "aws_organizations_policy_attachment.tag",
      ]

      khong_co_lint = "tag policy sinh tu bien tag_policy_keys chu khong tu catalog - phep kiem y nghia la gate.py, muc aws_organizations_policy_attachment"

      mo_ta = "Tag policy. Go khoi mot target la NOI."
    },
  ]

  catalogs = [
    {
      layer  = "landing-zone/organization"
      ten    = "SCP (catalog/scp.yaml)"
      lint   = "./lint.sh --strict"
      expiry = "./lint.sh --expiry"
    },
  ]

  ####################################
  # RANH GIOI GHI CUA PIPELINE NAY
  #
  # Nam o day chu khong trong module: moi pipeline co mot ranh gioi khac
  # nhau, va neu chung nam trong module thi tap quyen se la HOP cua moi
  # thu tung can.
  ####################################
  quyen_dich_vu = [
    ####################################
    # ORGANIZATIONS - DOC RONG
    #
    # plan refresh toan bo state cua layer organization, nen phai doc
    # duoc cay OU, delegated admin va tag policy - du khong sua.
    ####################################
    {
      Sid    = "DocToChuc"
      Effect = "Allow"
      Action = [
        "organizations:Describe*",
        "organizations:List*",
      ]
      Resource = "*"
    },

    ####################################
    # ORGANIZATIONS - GHI HEP
    #
    # DAY LA RANH GIOI THAT CUA PIPELINE NAY. Chin action, va chung
    # chi cham vao POLICY:
    #
    #   khong CreateAccount        khong tao account
    #   khong MoveAccount          khong doi OU cua account
    #   khong CreateOrganizationalUnit / Update / Delete
    #                              khong sua cay OU
    #   khong RegisterDelegatedAdministrator
    #                              khong cap quyen cho account khac
    #   khong EnablePolicyType / DisablePolicyType
    #                              khong tat ca loai policy - mot
    #                              lenh do go SACH moi SCP cung luc
    #
    # Loai cuoi dang chu y nhat: DisablePolicyType khong xoa policy
    # nao, no chi lam chung thoi co hieu luc. Console van hien day du
    # danh sach SCP, va khong con cai nao chan gi.
    ####################################
    {
      Sid    = "GhiChinhSach"
      Effect = "Allow"
      Action = concat([
        "organizations:CreatePolicy",
        "organizations:UpdatePolicy",
        "organizations:DeletePolicy",
        "organizations:AttachPolicy",
        "organizations:DetachPolicy",
        "organizations:TagResource",
        "organizations:UntagResource",
        ],
        ####################################
        # CAY OU - CHI KHI STAGE sec-ou DUOC BAT
        #
        # Ba action nay nam trong khoi Deny ben duoi khi stage tat. Do
        # la mot mau thuan CO THAT ma ban dau toi de lai: stage sec-ou
        # duoc them de quan cay OU, con IAM thi Deny dung nhung action
        # no can. Bat stage len se trot voi AccessDenied tren
        # UpdateOrganizationalUnit - va nguoi doc log se di tim loi
        # trong code OU, khong tim o day.
        #
        # Hai phia phai doi cung luc, nen ca hai deu doc
        # var.enable_ou_stage. Deny thang Allow trong IAM, nen KHONG du
        # neu chi them vao Allow.
        ####################################
        var.enable_ou_stage ? [
          "organizations:CreateOrganizationalUnit",
          "organizations:UpdateOrganizationalUnit",
          "organizations:DeleteOrganizationalUnit",
      ] : [])
      Resource = "*"
    }
  ]

  tu_choi_dich_vu = [{
    Sid    = "TuChoiViecNgoaiPhamVi"
    Effect = "Deny"
    Action = concat([
      "organizations:CreateAccount",
      "organizations:CloseAccount",
      "organizations:MoveAccount",
      "organizations:RemoveAccountFromOrganization",

      # EnablePolicyType / DisablePolicyType KHONG BAO GIO duoc mo,
      # ke ca khi stage sec-tagging bat. DisablePolicyType khong xoa
      # policy nao - no lam TOAN BO mot loai policy thoi co hieu luc,
      # va console van hien day du danh sach SCP.
      "organizations:EnablePolicyType",
      "organizations:DisablePolicyType",

      "organizations:RegisterDelegatedAdministrator",
      "organizations:DeregisterDelegatedAdministrator",
      "organizations:LeaveOrganization",
      "organizations:DeleteOrganization",
      ],
      # Cay OU: Deny khi stage sec-ou TAT.
      var.enable_ou_stage ? [] : [
        "organizations:CreateOrganizationalUnit",
        "organizations:UpdateOrganizationalUnit",
        "organizations:DeleteOrganizationalUnit",
    ])
    Resource = "*"
    }
  ]
}

########################################
# HA TANG PIPELINE
########################################

module "pipeline" {
  source = "../../modules/tf-pipeline"

  ten     = "ops"
  enable  = var.enable
  project = var.project
  region  = var.region

  stages          = local.stages
  catalogs        = local.catalogs
  quyen_dich_vu   = local.quyen_dich_vu
  tu_choi_dich_vu = local.tu_choi_dich_vu

  source_type       = var.source_type
  repository_name   = var.repository_name
  branch_name       = var.branch_name
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
