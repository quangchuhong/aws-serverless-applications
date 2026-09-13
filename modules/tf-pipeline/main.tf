########################################
# PHAN GENERIC CUA MOI PIPELINE VAN HANH
#
# Thu KHAI BAO (stage nao, catalog nao, quyen gi) nam o caller. File nay
# chi tinh toan tu chung.
#
# Xem versions.tf cho ly do tach module va cai bay `moved`.
########################################

locals {
  enabled = var.enable
  name    = "${var.project}-${var.ten}"

  ####################################
  # TOPIC BAO DRIFT: TU TAO HAY DUNG SAN
  #
  # drift_topic_arn thang neu khai ca hai - va check
  # "khong_khai_ca_hai_nguon_topic" keu ve dieu do, vi im lang chon mot
  # trong hai nghia la nhung dia chi trong drift_emails khong nhan duoc
  # gi ma khong ai biet.
  ####################################
  ####################################
  # PIPELINE NAY CO RULE COMMIT RIENG KHONG
  #
  # Tinh MOT LAN o day vi ba cho phai dong y: rule, target cua rule, va
  # dong "KICH HOAT" trong next_steps. Ba bieu thuc doc lap la ba cho de
  # lech - va cho de lech nhat la next_steps, vi no chi la van ban: no
  # noi sai ma khong hong gi ca.
  #
  # aws_iam_role.events CO Y khong nam trong so do: lich drift dung
  # chung role do, va lich drift khong lien quan gi den commit.
  ####################################
  kich_hoat_rieng = local.enabled && var.source_type == "codecommit" && var.tu_kich_hoat

  tao_topic   = var.drift_topic_arn == "" && length(var.drift_emails) > 0
  drift_topic = var.drift_topic_arn != "" ? var.drift_topic_arn : try(aws_sns_topic.drift[0].arn, "")

  ####################################
  # CATALOG -> JOBS CHO STAGE Lint / Expiry
  #
  # "<layer>=<lenh>", cach nhau bang ';' - lenh co dau cach nen khong
  # tach bang dau cach duoc.
  ####################################
  # Tinh MOT LAN o day. Ba cho dung no - project CodeBuild, stage Lint va
  # quyen StartBuild - phai dong y voi nhau, va ba bieu thuc doc lap la
  # ba cho de lech.
  co_catalog = length(var.catalogs) > 0

  lint_jobs = join(";", [for c in var.catalogs : "${c.layer}=${c.lint}"])
  expiry_jobs = join(";", [
    for c in var.catalogs : "${c.layer}=${c.expiry}" if c.expiry != ""
  ])

  ####################################
  # CHI STAGE DUOC BAT
  #
  # thu_tu danh lai TU DAU tren tap da loc, nen tat mot stage giua khong
  # de lai mot so thu tu trong - va mot so trong se thanh mot stage khong
  # co ten trong CodePipeline.
  #
  # ----------------------------------
  # THU TU ACTION TRONG MOT STAGE
  #
  # Co cong duyet:       Plan 1  ->  Duyet 2  ->  Apply 3  ->  Verify 4
  # Khong co cong duyet: Plan 1  ->  Apply 2  ->  Verify 3
  #
  # Tinh o day chu khong trong pipeline.tf: hai cho tinh doc lap la hai
  # cho de lech, va mot run_order lech KHONG gay loi - no chi lam Apply
  # chay SONG SONG voi cong duyet, tuc apply xong truoc khi co nguoi bam.
  ####################################
  stages = [
    for i, s in [for s in var.stages : s if s.enabled] :
    merge(s, {
      thu_tu   = i
      co_duyet = contains(var.approve_stages, s.key)
      ro_duyet = 2
      ro_apply = contains(var.approve_stages, s.key) ? 3 : 2
      ro_verify = contains(var.approve_stages, s.key) ? 4 : 3
    })
  ]

  ####################################
  # VERIFY - DOC LAI AWS SAU KHI APPLY
  #
  # Vi sao can, khi apply da bao thanh cong: apply chi noi rang Terraform
  # goi API va AWS tra ve 200. No khong noi policy da gan vao dau, hay no
  # co CHAN gi khong.
  #
  # Do la dung cai sai biet mat hai lan do moi tim ra: loi 121 (mot apply
  # xanh chua bao gio chung minh duoc apply DUOC) va loi 126 (mot SCP
  # dung noi dung van chan 0 thu neu go sai ten action).
  #
  # ----------------------------------
  # PHAM VI: CHI NHUNG GI DOC DUOC NGAY
  #
  # Verify chay NGAY sau apply, nen no chi tra loi duoc nhung cau co du
  # lieu ngay: policy gan vao dau, enforced_for co nhung gi, OU nao ton
  # tai. Nhung phep do TRE - bao cao tuan thu tag policy (toi 48 gio),
  # Config compliance (toi 1 gio) - KHONG thuoc day: dat chung vao mot
  # stage chay ngay sau apply thi chung se vinh vien in ra "chua co du
  # lieu", va mot dong luon giong nhau la mot dong khong ai doc nua.
  #
  # Nhung phep do do thuoc project DRIFT, chay theo lich.
  #
  # ----------------------------------
  # VERIFY CHAY BANG DANH TINH CUA CODEBUILD, KHONG ASSUME
  #
  # Khac Plan/Apply - chung truyen ASSUME_ROLE_ARN cho provider Terraform.
  # Script verify goi AWS CLI truc tiep, nen no o ACCOUNT MANAGEMENT.
  #
  # Du cho layer organization (Organizations chi tra loi tu management).
  # Mot stage can doc o account KHAC phai khai khong_co_verify kem ly do,
  # cho toi khi co co che assume cho buoc nay.
  ####################################
  co_verify = length([for s in local.stages : s.key if try(s.verify, "") != ""]) > 0

  stages_tat = [for s in var.stages : s.key if !s.enabled]

  ####################################
  # KHOA STATE CUA TUNG LAYER
  #
  # Tra cuu truc tiep chu khong try(): mot layer nam trong stages ma
  # thieu o layer_keys phai hong NGAY o day, kem ten khoa - chu khong
  # lang le thanh chuoi rong roi di toi tan `terraform init` voi mot
  # backend khong co key.
  #
  # Duyet local.stages (da loc) chu khong var.stages: bat buoc khai
  # layer_keys cho mot layer CHUA BAT se lam pipeline khong apply duoc
  # cho toi khi nguoi ta dien mot khoa cho thu ho chua dung.
  ####################################
  stage_keys = {
    for l in distinct([for s in local.stages : s.layer]) :
    l => var.layer_keys[l]
  }

  next_steps = <<-EOT

    ═══════════ ${local.name} - SAU KHI APPLY ═══════════

    1. DAY tfvars CUA CAC LAYER LEN KHO
       Pipeline doc tfvars tu s3://${var.tfvars_bucket}, KHONG tu git
       (tfvars nam trong .gitignore).

         cd ../vending-pipeline && ./push-tfvars.sh

       LUU Y: push-tfvars.sh phai biet ve ${join(", ", keys(local.stage_keys))}.
       Thieu thi khong co loi luc day - chi co loi luc pipeline chay.

    2. DAY CODE LEN CODECOMMIT
       Repo GitHub KHONG kich hoat gi ca.

    3. LAN CHAY DAU TIEN PHAI LA MOT LAN KHONG CO THAY DOI
       Moi stage phai ra "KHONG CO THAY DOI". De xem duong di co thong
       khong TRUOC khi mot thay doi that di qua no.

    4. BON LOP KIEM, va chung doc duoc nhung thu khac nhau

         Lint (stage dau)  moi catalog, offline. Mot loi schema dung
                           pipeline TRUOC khi stage nao cham vao AWS.
         gate.py           doc BAN PLAN sau plan. Biet chieu khac nhau:
                           xoa mot Deny la NOI, ma TAO mot assignment
                           cung la NOI.
         Duyet             NGUOI, o nhung stage trong approve_stages:
                           ${length(var.approve_stages) == 0 ? "KHONG CO STAGE NAO" : join(", ", var.approve_stages)}
         FAIL_ON_DESTROY   dem so resource bi xoa. Lop cuoi, va tho nhat.

       Ba lop dau khong thay duoc nhau. Lop thu ba la lop DUY NHAT doc
       duoc Y DINH - no tra loi "viec nay CO NEN xay ra khong".

    5. STAGE DANG TAT: ${length(local.stages_tat) == 0 ? "khong co" : join(", ", local.stages_tat)}

    5b. DUONG KICH HOAT: ${local.kich_hoat_rieng ? "RULE RIENG - MOI commit vao ${var.branch_name} deu lam pipeline nay chay, ke ca commit khong cham vao layer cua no." : (var.tu_kich_hoat ? "KHONG CO (source_type khong phai codecommit hoac pipeline dang tat)" : "QUA landing-zone/trigger-filter - rule rieng da TAT.")}
       ${local.kich_hoat_rieng ? "Tat no di bang tu_kich_hoat = false SAU KHI da bat landing-zone/trigger-filter." : (var.tu_kich_hoat ? "" : "Pipeline nay gio CHI chay khi ban do trong trigger-filter goi ten no. Thieu ten o do = khong bao gio chay nua, va khong co trieu chung.")}

    6. DRIFT: mot CodeBuild rieng chay theo lich "${var.drift_cron}"
       No chi `plan -lock=false`, khong bao gio apply.

       ${local.drift_topic == "" ? "CHUA khai drift_emails hay drift_topic_arn - khong ai duoc bao." : "Bao ve: ${local.drift_topic}"}

    ═══════════════════════════════════════════════════

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

########################################
# KHOA STAGE KHONG TRUNG
#
# Bang PHAM_VI trong ops-gate/gate.py la MOT ban dung chung cho moi
# pipeline van hanh, nen khoa stage phai duy nhat TOAN CUC - do la ly do
# khoa mang tien to chu so huu (sec-, cloudops-).
#
# Trong pham vi mot pipeline thi for_each o pipeline.tf dung
# format("%02d-%s", thu_tu, key), nen hai stage cung key VAN cho hai khoa
# map khac nhau - Terraform KHONG bao loi. Do la ly do phai kiem o day.
#
# GIOI HAN: check nay chi thay stage cua CHINH pipeline nay. Hai pipeline
# khac nhau dung chung mot key thi khong co cho nao trong Terraform thay
# duoc - gate.py se la noi hau qua lo ra.
########################################
check "khoa_stage_khong_trung" {
  assert {
    condition = length(var.stages) == length(distinct([for s in var.stages : s.key]))
    error_message = join(" ", [
      "Hai stage dung CUNG mot key:",
      join(", ", [for s in var.stages : s.key]),
      ". Bang PHAM_VI trong ops-gate/gate.py tra theo key, nen cai thu hai se",
      "lang le nhan pham vi cua cai thu nhat.",
    ])
  }
}

########################################
# MOI STAGE PHAI CO lint, HOAC NOI RO VI SAO KHONG CO
#
# Khong phai stage nao cung co catalog. OU va tag policy khong co, nen
# phep kiem y nghia cua chung la gate.py, doc tu ban plan.
#
# Nhung "khong co lint" phai duoc VIET RA kem ly do. Mot truong bo trong
# doc giong het mot truong bi quen, va cai thu hai la mot stage di qua ma
# khong ai kiem y nghia.
########################################
check "moi_stage_co_lint" {
  assert {
    condition = length([
      for s in var.stages : s.key
      if s.lint == "" && s.khong_co_lint == ""
    ]) == 0
    error_message = join(" ", [
      "Stage khong co lenh lint va cung khong khai khong_co_lint:",
      join(", ", [for s in var.stages : s.key if s.lint == "" && s.khong_co_lint == ""]),
      ". lint la lop kiem chay TRUOC khi Terraform cham vao AWS. Mot stage",
      "khong lint va khong giai thich la mot stage chi con FAIL_ON_DESTROY -",
      "va FAIL_ON_DESTROY khong biet gi ve y nghia, no chi dem so resource bi",
      "xoa.",
    ])
  }
}

########################################
# MOI STAGE PHAI CO VERIFY, HOAC MOT LY DO VI SAO KHONG
#
# Cung khuon voi moi_stage_co_lint, nhung bat mot khoang trong KHAC:
#
#   lint    kiem TRUOC khi Terraform cham vao AWS  - "co nen lam khong"
#   verify  doc lai AWS SAU khi apply              - "da lam duoc chua"
#
# Lop thu hai la lop duy nhat tra loi duoc cau hoi cua loi 121 va 126:
# apply bao thanh cong khong co nghia la thu do dang co tac dung. Mot SCP
# go sai ten action van apply thanh cong, van nam trong policy, va chan
# dung 0 thu.
#
# RONG LA HOP LE. Co stage that su khong verify duoc tu account
# management - luc do phai VIET RA, vi mot truong bo trong doc giong het
# mot truong bi quen.
########################################
check "moi_stage_co_verify" {
  assert {
    condition = length([
      for s in var.stages : s.key
      if s.enabled && s.verify == "" && s.khong_co_verify == ""
    ]) == 0
    error_message = join(" ", [
      "Stage dang BAT ma khong co lenh verify va cung khong khai khong_co_verify:",
      join(", ", [for s in var.stages : s.key if s.enabled && s.verify == "" && s.khong_co_verify == ""]),
      ". verify la lop DUY NHAT doc lai AWS sau khi apply. Thieu no thi cau",
      "\"apply da co tac dung chua\" khong co ai tra loi - va cau tra loi",
      "mac dinh se la mau xanh cua stage Apply, thu chi noi rang AWS da tra",
      "ve 200.",
    ])
  }
}

########################################
# CATALOG PHAI CO IT NHAT MOT MUC
#
# var.catalogs rong lam JOBS thanh chuoi rong, va stage Lint se chay 0
# vong lap. buildspec co chot chan cho viec do, nhung bat o day thi bat
# duoc SOM hon mot vong - luc apply, khong phai luc pipeline chay.
########################################
check "co_catalog_de_lint" {
  assert {
    condition = length(var.catalogs) > 0 || var.khong_co_catalog != ""
    error_message = join(" ", [
      "var.catalogs RONG va cung khong khai khong_co_catalog.",
      "Rong la hop le - khong phai layer nao cung co catalog - nhung no phai",
      "duoc VIET RA kem ly do. Mot truong bo trong doc giong het mot truong bi",
      "quen, va cai thu hai la mot pipeline di qua ma khong ai kiem catalog.",
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
      ". Them khoa state cho no vao layer_keys, hoac tat stage do.",
    ])
  }
}

########################################
# TEN TRONG approve_stages PHAI LA TEN STAGE THAT
#
# Go sai mot ten o day KHONG gay loi: contains() tra ve false, stage do
# khong co cong duyet, va pipeline chay binh thuong. Ket qua la mot cong
# duyet duoc khai ma khong ton tai - va no tra loi cau hoi "SCP co can
# duyet khong" bang "co" trong tfvars trong khi thuc te la khong.
########################################
check "approve_stages_la_ten_that" {
  assert {
    condition = length(setsubtract(
      toset(var.approve_stages),
      toset([for s in var.stages : s.key]),
    )) == 0
    error_message = join(" ", [
      "approve_stages co ten khong phai stage nao cua pipeline nay:",
      join(", ", tolist(setsubtract(
        toset(var.approve_stages),
        toset([for s in var.stages : s.key]),
      ))),
      ". Ten stage co the la:",
      join(", ", [for s in var.stages : s.key]),
      ". Go sai o day KHONG gay loi luc chay - no chi lam cong duyet do khong",
      "ton tai, trong khi tfvars noi rang co.",
    ])
  }
}
