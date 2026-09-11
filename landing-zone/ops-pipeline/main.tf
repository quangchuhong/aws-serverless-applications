########################################
# PIPELINE VAN HANH - CAC LAYER DOI HANG NGAY
#
# Chay o ACCOUNT MANAGEMENT, canh vending-pipeline nhung TACH HAN.
#
# --------------------------------------------------------------
# VI SAO KHONG GOP VAO vending-pipeline
#
# Hai pipeline nay doi lap nhau o moi chieu:
#
#                 vending              ops
#   Tan so        khi can account moi  hang ngay
#   Ban kinh      lon nhat (tao        nho, DO THIET KE
#                 account, sua TGW)
#   Cong duyet    bat buoc o stage A   khong nen co
#   Dau vao       catalog + tfvars     catalog (da nam trong git)
#
# Gop lai thi moi lan mo mot port hay them mot Deny se:
#
#   1. Chay stage B va D - layer network, tuc TGW, firewall va moi
#      VPC cua to chuc.
#   2. Dung o cong duyet cua stage A, vi stage do LUON chay.
#
# Dieu thu hai mot minh da du lam pipeline vo dung cho van hanh hang
# ngay: khong ai bam duyet mot thay doi DNS record ba lan mot ngay.
#
# --------------------------------------------------------------
# KHONG CO CONG DUYET, VA DO LA MOT LUA CHON CO LY
#
# Voi vending, thu can doc la BAN PLAN: hau qua (mot account voi email
# vinh vien) khong hien ra trong diff cua catalog.
#
# Voi ops thi nguoc lai - diff cua catalog CHINH LA thay doi:
#
#   + - sid: DenyRdsDeleteProd
#   +   action: ["rds:DeleteDBInstance"]
#   +   ticket: SEC-2291
#
# Ba dong do noi ro hon bat ky ban plan Terraform nao. Nen cho duyet
# dung la PR tren git, khong phai mot cong trong CodeBuild noi nguoi
# ta bam tu dien thoai.
#
# Doi lai, hai lop bu:
#
#   1. FAIL_ON_DESTROY=yes - plan co xoa hoac thay the thi dung ngay o
#      buoc plan, chua apply gi.
#   2. lint cua tung layer chay TRUOC moi stage. Voi SCP, lint phan
#      biet THAT voi NOI va tu choi moi thay doi noi long khong mang
#      khoi `loosen`. Xem organization/lint.sh.
#
# --------------------------------------------------------------
# LAP LAI CODE VOI vending-pipeline - CO Y, TAM THOI
#
# Layer nay khong dung chung module voi vending-pipeline, nen buildspec
# va phan IAM co cho giong nhau. Do la mot khoan no ky thuat CO Y:
#
#   - vending-pipeline dang la duong chay cho phep do mot-luot
#     (app-prod-5). Tach module la sua ca hai cung luc, va sua mot thu
#     dang duoc do la cach chac chan nhat de khong biet ket qua do la
#     cua cai gi.
#
# Sau khi phep do do xong, buoc dung la tach modules/tf-pipeline/ va
# cho ca hai dung chung. Ghi ra day de no khong thanh no im lang.
########################################

locals {
  enabled = var.enable
  name    = "${var.project}-ops"

  ####################################
  # TOPIC BAO DRIFT: TU TAO HAY DUNG SAN
  #
  # drift_topic_arn thang neu khai ca hai - va check
  # "khong_khai_ca_hai_nguon_topic" keu ve dieu do, vi im lang chon mot
  # trong hai nghia la nhung dia chi trong drift_emails khong nhan duoc
  # gi ma khong ai biet.
  ####################################
  tao_topic   = var.drift_topic_arn == "" && length(var.drift_emails) > 0
  drift_topic = var.drift_topic_arn != "" ? var.drift_topic_arn : try(aws_sns_topic.drift[0].arn, "")

  ####################################
  # CATALOG - LINT OFFLINE, CHAY TRUOC MOI THU
  #
  # HAI LINT KHAC NHAU, va cho nay tung bi lan:
  #
  #   offline   schema, sid trung, do dai 5120, tu khoa chinh minh.
  #             Khong can AWS, khong can state, khong can credential.
  #   --aws     doi chieu voi policy DANG GAN THAT. Can backend va
  #             credential cua layer.
  #
  # Ban dau pipeline.tf ghi rang lint "KHONG the la mot stage rieng", va
  # ly do no neu la `--aws` can backend cua tung layer. Ly do do dung -
  # nhung chi cho `--aws`. Lint OFFLINE khong can gi ca, nen no la mot
  # stage rieng duoc, va NEN la:
  #
  #   mot loi schema o catalog cua layer thu ba phai dung pipeline TRUOC
  #   khi stage dau cham vao AWS - khong phai sau khi hai stage dau da
  #   apply xong.
  #
  # Nen: offline lint gom het vao mot stage dau, `--aws` giu nguyen cho
  # cu trong action Plan cua tung layer.
  ####################################
  catalogs = [
    {
      layer  = "landing-zone/organization"
      ten    = "SCP (catalog/scp.yaml)"
      lint   = "./lint.sh --strict"
      expiry = "./lint.sh --expiry"
    },
    # Them layer khi catalog cua no ton tai:
    #   landing-zone/config-detective/ops   Config rule
    #   landing-zone/permission-sets/ops    ai vao account nao
  ]

  # "<layer>=<lenh>", cach nhau bang ';' - lenh co dau cach nen khong
  # tach bang dau cach duoc.
  lint_jobs = join(";", [for c in local.catalogs : "${c.layer}=${c.lint}"])
  expiry_jobs = join(";", [
    for c in local.catalogs : "${c.layer}=${c.expiry}" if try(c.expiry, "") != ""
  ])

  ####################################
  # STAGE, KHAI THANH DU LIEU
  #
  # Them mot layer vao pipeline la them MOT DONG o day.
  #
  # Thu tu trong danh sach la thu tu chay - xem for_each o pipeline.tf.
  # KHONG dua vao ten stage de sap xep: do la loi 113, va no da xay ra
  # mot lan o vending-pipeline.
  #
  # --------------------------------------------------------------
  # `enabled` KHONG PHAI CO CHO SANG TRONG
  #
  # Mot stage tro vao layer CHUA TON TAI, hoac vao layer co state RONG,
  # se dung o chot chan "state RONG" cua buildspec - va thong bao o do
  # noi ve SAI KHOA STATE, khong noi rang layer chua duoc dung. Doc log
  # do se dan nguoi ta di sua backend, dung cho khong hong.
  #
  # network/ops la vi du dang co that: layer ton tai, da tach state tu
  # truoc, nhung state dang RONG vi network vua bi xoa de do tien.
  ####################################
  stages_all = [
    {
      key     = "A-scp"
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
    # permission-sets/ops - STATE RIENG
    #
    # CHI "ai vao account nao". Noi dung quyen o layer cha: doi mot
    # managed policy attachment la doi quyen cua MOI nguoi dang dung
    # permission set do, o MOI account, ngay lap tuc - va Identity
    # Center day thay doi do xuong moi role da sinh ma khong ai phai
    # dang nhap lai. Do khong phai viec hang ngay.
    #
    # Chay trong CHINH account management, khong can role lien account.
    ####################################
    {
      key     = "B-permission-set-assignment"
      layer   = "landing-zone/permission-sets/ops"
      enabled = var.enable_permission_set_ops

      targets = [
        "aws_ssoadmin_account_assignment.ops",
        "aws_identitystore_group_membership.ops",
      ]

      lint  = "./lint.sh --aws --strict"
      mo_ta = "Ai vao account nao. TAO mot assignment la NOI - chieu nguoc voi SCP."
    },

    ####################################
    # config-detective/ops - STATE RIENG
    #
    # Config rule doi hang ngay (them mot rule, doi mot tham so), nen no
    # bien minh duoc mot state rieng. Recorder, aggregator, Security Hub
    # va GuardDuty KHONG o day - chung doi vai lan mot nam, va mot
    # pipeline tu apply duoc chung la mot pipeline co the tat ca he
    # thong phat hien cua to chuc.
    #
    # CHUA BAT DUOC: Config rule song o ACCOUNT SECURITY -
    # aggregator-rules.tf:80 ghi `provider = aws.security`. Layer nay se
    # can sts:AssumeRole lien account, va hom nay chi co
    # OrganizationAccountAccessRole = full admin o do. Do la dung cai
    # role da hoan lai den sau phep do app-prod-5.
    ####################################
    {
      key     = "C-config-rules"
      layer   = "landing-zone/config-detective/ops"
      enabled = var.enable_config_rules_ops

      targets = [
        "aws_config_organization_managed_rule.ops",
      ]

      lint  = "./lint.sh --aws --strict"
      mo_ta = "Config rule tu catalog. Xoa rule hoac them account vao excluded_accounts la NOI."
    },

    ####################################
    # network/ops - DA co state rieng tu truoc
    #
    # Layer nay la khuon mau cho hai cai tren: no doc layer cha qua
    # terraform_remote_state va giu state rieng.
    #
    # CHUA BAT DUOC vi ly do khac han: state dang RONG. network vua bi
    # xoa de do tien, nen bat stage nay se cho ra mot loi noi ve sai
    # khoa state.
    ####################################
    {
      key     = "D-network-ops"
      layer   = "landing-zone/network/ops"
      enabled = var.enable_network_ops

      targets = []

      lint  = "./verify-catalog.sh"
      mo_ta = "DNS record, endpoint, rule group, ingress rule. TAO mot ingress rule la NOI."
    },
  ]

  # CHI stage duoc bat. thu_tu danh lai TU DAU tren tap da loc, nen tat
  # mot stage giua khong de lai mot so thu tu trong - va mot so trong se
  # thanh mot stage khong co ten trong CodePipeline.
  stages = [
    for i, s in [for s in local.stages_all : s if s.enabled] :
    merge(s, { thu_tu = i })
  ]

  stages_tat = [for s in local.stages_all : s.key if !s.enabled]

  # Khoa state cua tung layer. Tra cuu truc tiep chu khong try(): mot
  # layer nam trong stages ma thieu o layer_keys phai hong NGAY o day,
  # kem ten khoa - chu khong lang le thanh chuoi rong roi di toi tan
  # `terraform init` voi mot backend khong co key.
  #
  # Duyet local.stages (da loc) chu khong stages_all: bat buoc khai
  # layer_keys cho mot layer CHUA BAT se lam layer nay khong apply duoc
  # cho toi khi nguoi ta dien mot khoa cho thu ho chua dung.
  stage_keys = {
    for l in distinct([for s in local.stages : s.layer]) :
    l => var.layer_keys[l]
  }

  next_steps = <<-EOT

    ═══════════════ SAU KHI APPLY ═══════════════

    1. DAY tfvars CUA CAC LAYER OPS LEN KHO
       Pipeline doc tfvars tu s3://${var.tfvars_bucket}, KHONG tu git
       (tfvars nam trong .gitignore). Them layer moi thi phai day file
       cua no len, neu khong stage se dung lai voi mot loi ro rang.

         cd ../vending-pipeline && ./push-tfvars.sh

       LUU Y: push-tfvars.sh phai biet ve ${join(", ", keys(local.stage_keys))}.
       Thieu thi khong co loi luc day - chi co loi luc pipeline chay.

    2. DAY CODE LEN CODECOMMIT
       Repo GitHub KHONG kich hoat gi ca.

    3. LAN CHAY DAU TIEN PHAI LA MOT LAN KHONG CO THAY DOI
       Moi stage phai ra "KHONG CO THAY DOI". De xem duong di co thong
       khong TRUOC khi mot thay doi that di qua no.

    4. KHONG CO CONG DUYET - do la co y
       Cho duyet la PR tren git. Doi lai BA lop, khong phai mot:

         Lint (stage dau)  moi catalog, offline. Mot loi schema dung
                           pipeline TRUOC khi stage nao cham vao AWS.
         gate.py           doc BAN PLAN sau plan. Biet chieu khac nhau:
                           xoa mot Deny la NOI, ma TAO mot assignment
                           cung la NOI.
         FAIL_ON_DESTROY   dem so resource bi xoa. Lop cuoi, va la lop
                           tho nhat - no khong biet y nghia.

    5. STAGE DANG TAT: ${length(local.stages_tat) == 0 ? "khong co" : join(", ", local.stages_tat)}
       Mot stage tro vao layer chua ton tai, hoac vao layer co state
       RONG, se dung o chot chan "state RONG" cua buildspec - va thong
       bao o do noi ve SAI KHOA STATE chu khong noi rang layer chua duoc
       dung. Xem mo ta cua tung bien enable_* de biet phai co gi truoc.

    6. DRIFT: mot CodeBuild rieng chay theo lich "${var.drift_cron}"
       No chi `plan -lock=false`, khong bao gio apply. Mot lan chay ra
       KHAC "khong co thay doi" nghia la co nguoi sua tay.

       ${local.drift_topic == "" ? "CHUA khai drift_emails hay drift_topic_arn - khong ai duoc bao." : "Bao ve: ${local.drift_topic}"}

    ═════════════════════════════════════════════

  EOT
}

########################################
# KIEM TRA CHEO
########################################

check "khoa_state_khong_trung" {
  assert {
    condition = length(values(var.layer_keys)) == length(distinct(values(var.layer_keys)))
    error_message = join(" ", [
      "Hai layer dang tro vao CUNG mot khoa state:",
      join(", ", [for k, v in var.layer_keys : "${k} -> ${v}"]),
      ". Hai layer dung chung mot state se giam len nhau, va cai apply sau se",
      "coi resource cua cai truoc la thu can xoa.",
    ])
  }
}

check "moi_stage_co_lint" {
  assert {
    condition = length([for s in local.stages_all : s.key if try(s.lint, "") == ""]) == 0
    error_message = join(" ", [
      "Stage khong co lenh lint:",
      join(", ", [for s in local.stages_all : s.key if try(s.lint, "") == ""]),
      ". Pipeline nay KHONG co cong duyet, nen lint la lop kiem duy nhat chay",
      "truoc khi Terraform cham vao AWS. Mot stage khong lint la mot stage",
      "chi con FAIL_ON_DESTROY - va FAIL_ON_DESTROY khong biet gi ve y nghia",
      "cua thay doi, no chi dem so resource bi xoa.",
    ])
  }
}

########################################
# CHECK NAY CHI PHU MOT LAYER - VA DO LA GIOI HAN CUA NO
#
# Dieu kien viet cung `layer == "landing-zone/organization"`. Nen
# permission-sets/ops hay org-trail co the khai thieu targets ma check
# nay khong keu.
#
# Cho chan tong quat KHONG o day ma o gate/gate.py: bang PHAM_VI khai
# type nao mot stage duoc doi, va no kiem o BAN PLAN chu khong o bien
# moi truong - nen no thay thu that su sap doi, bat ke TF_TARGETS duoc
# dat dung hay bi de len thanh rong.
#
# Giu check nay lai vi no bat SOM hon (luc plan cua chinh layer
# ops-pipeline, khong phai luc pipeline chay), va vi layer organization
# la layer duy nhat mot dong thieu se thao SCP cua ca to chuc.
########################################
check "stage_khong_cham_ngoai_pham_vi" {
  assert {
    condition = length([
      for s in local.stages_all : s.key
      if s.layer == "landing-zone/organization" && length(try(s.targets, [])) == 0
    ]) == 0
    error_message = join(" ", [
      "Stage tro vao layer organization ma KHONG khai targets.",
      "Layer do quan ca cay OU, delegated administrator va tag policy.",
      "Khong gioi han thi pipeline nay apply duoc CA CHUNG - va mot lan doi",
      "cay OU tu dong la mot lan moi target cua SCP phai giai lai, tuc ca to",
      "chuc co the khong con SCP nao gan vao dau.",
    ])
  }
}

########################################
# CATALOG PHAI CO IT NHAT MOT MUC
#
# local.catalogs rong lam JOBS thanh chuoi rong, va stage Lint se chay 0
# vong lap. buildspec co chot chan cho viec do, nhung bat o day thi bat
# duoc SOM hon mot vong - luc apply layer nay, khong phai luc pipeline
# chay.
########################################
check "co_catalog_de_lint" {
  assert {
    condition = length(local.catalogs) > 0
    error_message = join(" ", [
      "local.catalogs RONG, nen stage Lint se khong kiem catalog nao va van",
      "bao THANH CONG neu chot chan trong buildspec bi bo. Mot cong kiem bao",
      "dat vi no khong kiem gi la kieu hong im lang nhat.",
    ])
  }
}

########################################
# MOI STAGE DUOC BAT PHAI CO KHOA STATE
#
# Tra cuu var.layer_keys[l] o local.stage_keys da hong san khi thieu,
# nhung thong bao cua Terraform cho viec do noi ve "key not found" va
# khong noi phai lam gi. Check nay noi.
########################################
check "stage_bat_thi_co_khoa_state" {
  assert {
    condition = length(setsubtract(
      toset([for s in local.stages : s.layer]),
      toset(keys(var.layer_keys)),
    )) == 0
    error_message = join(" ", [
      "Stage duoc BAT nhung layer cua no khong co trong layer_keys:",
      join(", ", tolist(setsubtract(
        toset([for s in local.stages : s.layer]),
        toset(keys(var.layer_keys)),
      ))),
      ". Them khoa state cho no vao layer_keys, hoac tat stage do bang bien",
      "enable_* tuong ung.",
    ])
  }
}
