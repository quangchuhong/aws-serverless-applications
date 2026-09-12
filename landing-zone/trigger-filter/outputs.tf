locals {
  ####################################
  # LE CUA DONG DAU KHAC LE CUA DONG SAU
  #
  # `<<-EOT` cat le theo dong THUT IT NHAT trong ca khoi. Mot bieu thuc
  # noi cac dong bang "\n    " thi bon dau cach do la NOI DUNG, khong
  # phai le - chung khong bi cat, con le cua dong dau thi bi. Ket qua:
  # dong dau sat trai, nhung dong sau thut vao.
  #
  # Chua bang cach de bieu thuc sinh ra dung mot dong lien, va viec thut
  # le do heredoc lo - tuc chi mot cho quyet dinh.
  #
  # Cung ly do bieu thuc duoi day noi chuoi thay vi goi format() nhieu
  # tham so xuong dong: `terraform fmt` thut lai loi goi nhieu dong theo
  # cach kho doan truoc, va moi truong nay khong co terraform de thu.
  ####################################
  bang_ban_do = join("\n", [
    for t, p in local.ban_do :
    "${format("%-34s", t)}${join(" ", p)}${length(lookup(local.tru, t, [])) == 0 ? "" : "  [tru ${join(" ", lookup(local.tru, t, []))}]"}"
  ])

  ####################################
  # Heredoc phai nam o local, khong nam trong mot ternary.
  #
  # Dat <<-EOT ben trong `cond ? <<-EOT ... : ""` lam Terraform bao
  # "Unterminated template string": dau ket thuc phai dung MOT MINH tren
  # mot dong, va trong ternary thi khong the.
  ####################################
  huong_dan = <<-EOT

    ═══════════ ${local.name} ═══════════

    BAN DO HIEN TAI
    ${local.bang_ban_do}

    LAYER KHONG CO DUONG TU DONG (khai o layer_thu_cong)
    ${length(var.layer_thu_cong) == 0 ? "khong co - moi layer duoc pipeline apply deu co duong kich hoat" : join("\n", var.layer_thu_cong)}

    Thay doi trong nhung layer tren vao main roi NAM DO. Phai apply bang
    tay, hoac bat pipeline cua chung len.

    Kiem do phu: ${var.kiem_do_phu ? "BAT - moi pipeline mang tien to \"${var.project}-\" ma thieu o ban do se lam ham bao hong" : "TAT"}
    Bao khi hong: ${local.loi_topic == "" ? "KHONG AI DUOC BAO" : local.loi_topic}

    ───────────────────────────────────────────────────
    THU TU BAT - MOT CHIEU AN TOAN, MOT CHIEU IM LANG

    1. Apply layer NAY truoc (enable = true).
    2. Roi moi tat rule rieng cua tung pipeline:

         tu_kich_hoat = false

       trong tfvars cua ops-pipeline, ops-pipeline-permission-set,
       ops-pipeline-network, ops-pipeline-config-rules,
       ops-pipeline-trail va vending-pipeline.

    Giua hai buoc do moi pipeline bi kich hoat HAI lan. Vo hai -
    CodePipeline thay the ban dang cho bang ban moi.

    Lam NGUOC lai thi giua hai buoc KHONG CO gi kich hoat pipeline nao,
    va khong co trieu chung nao: console van xanh, pipeline chi khong
    bao gio chay.

    ───────────────────────────────────────────────────
    BA PHEP THU - PHEP THU (c) LA PHEP DUY NHAT CHUNG MINH CO TAC DUNG

    (a) Push mot thay doi CHI trong docs/
        -> khong pipeline nao chay.
        Xem log:
          aws logs tail /aws/lambda/${local.name} --follow --region ${var.region}
        Phai thay "bo qua" cho MOI pipeline.

    (b) Push mot thay doi trong landing-zone/account-baseline/
        -> CHI ${var.project}-vending chay.

    (c) PHEP THU THAT: push mot thay doi trong landing-zone/organization/
        -> ${var.project}-ops chay, va ${var.project}-vending KHONG chay.

        (a) va (b) van dat neu bo loc bi bo qua hoan toan va moi pipeline
        deu chay - o (a) thi "khong ai chay" trong giong "chay het roi
        khong co gi de lam". Chi (c) phan biet duoc hai truong hop do, vi
        no doi hoi mot pipeline chay VA mot pipeline khong chay trong
        cung mot lan push.

    ───────────────────────────────────────────────────
    KHI BO LOC HONG

    So Errors cua ham Lambda la dau vet duy nhat. ${local.co_bao_loi ? "Da co duong bao." : "CHUA CO DUONG BAO - khai loi_emails."}

    Doc tay mot su kien da bi vut:
      aws logs tail /aws/lambda/${local.name} --since 1h --region ${var.region}

    Chay lai bang tay khi can (khong can bo loc):
      aws codepipeline start-pipeline-execution --name <ten> --region ${var.region}

    ═══════════════════════════════════════════════════

  EOT
}

output "function_name" {
  value = local.enabled ? aws_lambda_function.loc[0].function_name : ""
}

output "log_group" {
  value = local.enabled ? aws_cloudwatch_log_group.loc[0].name : ""
}

########################################
# BAN DO DA GHEP TEN DAY DU
#
# Xuat ra de doi chieu duoc bang mat voi `aws codepipeline list-pipelines`
# ma khong phai tu ghep tien to trong dau.
########################################
output "ban_do" {
  value = local.ban_do
}

output "loi_topic_arn" {
  value = local.loi_topic
}

output "huong_dan" {
  value = local.enabled ? local.huong_dan : "trigger-filter dang TAT (enable = false). Moi pipeline van dung rule rieng cua no, tuc moi push deu kich hoat tat ca."
}
