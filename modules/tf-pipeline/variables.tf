########################################
# BIEN
########################################

variable "enable" {
  description = <<-EOT
    MAC DINH TAT.

    Bat cai nay tao mot duong TU DONG co quyen sua SCP cua ca to chuc.
    SCP la tran quyen cho moi account - mot thay doi sai o day khong
    lam gi "hong", no chi lam mot viec truoc day bi chan gio chay duoc.

    Doc README truoc, nhat la muc "Khong co cong duyet".
  EOT
  type        = bool
  default     = false
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project" {
  description = "Tien to ten. Pipeline se ten <project>-ops."
  type        = string
}



########################################
# NGUON
########################################

variable "source_type" {
  description = <<-EOT
    codecommit hoac s3.

    Repo GitHub KHONG kich hoat pipeline. Hai remote la hai ban sao -
    phai day ca hai:
      git push codecommit HEAD:main
  EOT
  type        = string
  default     = "codecommit"

  validation {
    condition     = contains(["codecommit", "s3"], var.source_type)
    error_message = "source_type phai la codecommit hoac s3."
  }
}

variable "tu_kich_hoat" {
  description = <<-EOT
    Pipeline nay co rule EventBridge RIENG bat moi commit vao nhanh hay
    khong.

    -------------------------------------------------------------------
    VI SAO CAN TAT DUOC

    Rule rieng do KHONG loc theo duong dan - no khong the. Su kien
    "CodeCommit Repository State Change" chi mang repositoryName,
    commitId, oldCommitId, referenceName; danh sach file khong co trong
    do. Nen sua mot dong trong docs/ cung lam MOI pipeline chay.

    landing-zone/trigger-filter dung mot ham o giua: no goi
    GetDifferences roi khoi dong dung nhung pipeline co duong dan bi
    cham. Khi layer do BAT, rule rieng o day phai TAT - neu khong thi ca
    hai duong cung no va bo loc thanh vo nghia.

    -------------------------------------------------------------------
    THU TU

    BAT trigger-filter TRUOC, roi moi dat false o day.

    Lam nguoc lai thi giua hai lan apply khong co gi kich hoat pipeline
    nao - va do la kieu hong khong co trieu chung.

    -------------------------------------------------------------------
    CAI NAY KHONG TAT LICH DRIFT

    Lich drift la mot rule khac (aws_cloudwatch_event_rule.drift) va no
    KHONG lien quan den commit. Hai rule dung CHUNG mot IAM role
    (aws_iam_role.events), nen role do co y KHONG bi tat theo bien nay.
  EOT
  type        = bool
  default     = true
}

variable "repository_name" {
  description = <<-EOT
    Repo phai chua CA BO landing-zone/, khong chi layer nay: buildspec
    `cd landing-zone/organization`, nen mot repo chi co code pipeline se
    hong ngay o lenh cd dau tien.
  EOT
  type        = string
  default     = ""
}

variable "branch_name" {
  type    = string
  default = "main"
}

variable "source_bucket" {
  type    = string
  default = ""
}

variable "source_object_key" {
  type    = string
  default = ""
}

########################################
# STATE
########################################

variable "state_bucket" {
  description = <<-EOT
    Bucket chua state cua cac layer ops.

      cd ../tf-backend && terraform output bucket
  EOT
  type        = string
}

variable "state_lock_table" {
  description = <<-EOT
    Bang DynamoDB khoa state. De rong = khong khoa.

    De rong tren mot pipeline TU DONG la mot lua chon te: hai lan chay
    chong nhau se ghi len state cua nhau, va khong co gi bao.
  EOT
  type        = string
  default     = ""
}

variable "layer_keys" {
  description = <<-EOT
    Duong dan layer -> khoa state. PHAI khop chinh xac.

    Sai khoa thi Terraform mo mot state RONG: plan doi tao lai toan bo,
    va buildspec se dung lai o chot chan "state RONG" - nhung chi khi
    FIRST_APPLY khong bang yes.

      cd ../tf-backend && terraform output layers
  EOT
  type        = map(string)

  ####################################
  # KHONG CO MAC DINH - CO CHU DICH
  #
  # Truoc ban nay o day co:
  #
  #   default = { "landing-zone/organization" = "organization/..." }
  #
  # Mac dinh do vo hai khi file nay chi thuoc mot pipeline. Khi no thanh
  # module DUNG CHUNG thi no la mot cai bay: pipeline cua cloudops quen
  # truyen layer_keys se LANG LE dung khoa state cua layer organization,
  # va cac stage cua no se plan tren state cua SCP.
  #
  # Va chinh mo ta ben tren da noi vi sao: "Sai khoa thi Terraform mo mot
  # state RONG: plan doi tao lai toan bo". Mot mac dinh o day la mot cach
  # sai khoa ma khong ai go sai gi.
  #
  # Phat hien duoc nho mot phep DOT BIEN THAT BAI: bo input layer_keys
  # khoi module block, va bo kiem bao "khop het" - dung, vi co mac dinh.
  # Mot dot bien khong bat duoc doi khi noi ve code chu khong ve bo kiem.
  ####################################
}

########################################
# KHO tfvars
########################################

########################################
# STATE CUA LAYER KHAC - CHI DOC
#
# Mot layer co the DOC state cua layer khac qua terraform_remote_state.
# Khi do khoa state do la mot phan BE MAT QUYEN cua pipeline, va
# layer_keys khong phu duoc: layer_keys cap ca GhiObject, ma pipeline
# tuyet doi khong duoc ghi vao state cua layer khac.
#
# Phat hien bang mot lan chay that, khong bang suy luan:
#
#   data.terraform_remote_state.vending[0]: Reading...
#   Error: Unable to access object "account-baseline/terraform.tfstate"
#   in S3 bucket "...": StatusCode: 403, Forbidden
#
# Layer permission-sets doc state cua account-baseline de lay danh sach
# account vua vend. Khong co dong nay thi plan CHET - va thong bao noi ve
# S3 403, khong noi rang mot phu thuoc state chua duoc khai.
########################################

variable "state_chi_doc" {
  description = <<-EOT
    Khoa state cua nhung layer KHAC ma layer cua pipeline nay DOC qua
    terraform_remote_state. Chi cap s3:GetObject - khong bao gio cap ghi.

    Tim bang cach doc chinh layer do:

      grep -rn 'terraform_remote_state' <layer>/*.tf

    Roi xem no doc khoa nao (thuong qua mot bien kieu vending_state),
    va tra khoa do o tf-backend/outputs.tf muc local.layers.

    RONG la hop le - phan lon layer khong doc state cua ai. Nhung neu
    layer CO doc ma bien nay rong thi plan chet voi mot loi 403 cua S3,
    va loi do khong nhac gi toi terraform_remote_state.
  EOT
  type        = list(string)
  default     = []
}

variable "tfvars_bucket" {
  description = <<-EOT
    Bucket chua terraform.tfvars cua cac layer. DUNG CHUNG voi
    vending-pipeline - co y.

    Vi sao khong tao kho rieng: hai kho la hai cho phai day file, va
    mot kho cu la mot ban plan SAI ma khong co loi nao. Mot kho, mot
    script (push-tfvars.sh), mot cho de nham.

      cd ../vending-pipeline && terraform output -raw tfvars_bucket

    Khoa co dang: tfvars/<duong dan layer>/terraform.tfvars
  EOT
  type        = string

  validation {
    condition     = var.tfvars_bucket != ""
    error_message = "tfvars_bucket bat buoc. Lay: cd ../vending-pipeline && terraform output -raw tfvars_bucket"
  }
}

########################################
# PHAT HIEN DRIFT
########################################

variable "drift_cron" {
  description = <<-EOT
    Lich chay buoc phat hien drift, dang cron cua EventBridge (UTC).

    Mac dinh 19:00 UTC = 2 gio sang gio Viet Nam - sau gio lam, truoc
    gio lam ngay hom sau, nen ket qua co nguoi doc vao buoi sang.

    Buoc nay CHI `terraform plan -lock=false`. Khong bao gio apply, va
    -lock=false de no khong bao gio chan mot lan apply that.
  EOT
  type        = string
  default     = "cron(0 19 * * ? *)"
}

variable "drift_emails" {
  description = <<-EOT
    Dia chi nhan bao drift. Khai o day thi layer nay TU TAO topic o
    account management.

    NEN DUNG CACH NAY thay vi drift_topic_arn tro sang account khac.
    Publish lien account can CA HAI phia cho phep: IAM cua role o day,
    VA resource policy cua topic ben kia. Topic cua config-detective
    chi cho Principal = events.amazonaws.com, nen mot ARN tro sang do
    se bi tu choi - va buoc drift se in "khong bao duoc ve SNS" moi
    dem ma khong ai doc.

    Moi dia chi nhan mot thu tu SNS va PHAI BAM XAC NHAN. Truoc do
    subscription o PendingConfirmation va khong nhan gi - Terraform van
    bao tao thanh cong.
  EOT
  type        = list(string)
  default     = []
}

variable "drift_topic_arn" {
  description = <<-EOT
    Dung mot topic CO SAN thay vi tao moi. Loai tru voi drift_emails.

    Neu topic nam o ACCOUNT KHAC thi phai tu them statement cho phep
    role cua layer nay publish - Terraform o day khong sua duoc
    resource policy cua topic o account khac.

    Lay ARN topic cua config-detective (o account security):
      cd ../config-detective && terraform output alert_topic

    LUU Y ten: topic do la "<project>-security-findings", va output ten
    la `alert_topic`. Dung doan ten - mot ARN go tay trong nhu that se
    duoc dung nhu that, va loi duy nhat la mot dong canh bao trong log
    luc 2 gio sang.
  EOT
  type        = string
  default     = ""
}

########################################
# NGUONG
########################################

variable "build_timeout_minutes" {
  description = <<-EOT
    Layer organization apply nhanh (chi SCP), nhung `plan` refresh CA
    state - gom cay OU va tag policy - nen van mat vai phut o to chuc
    lon.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.build_timeout_minutes >= 5 && var.build_timeout_minutes <= 480
    error_message = "build_timeout_minutes trong khoang 5..480."
  }
}

variable "log_retention_days" {
  type    = number
  default = 90
}

########################################
# BAT/TAT TUNG STAGE
#
# Mac dinh TAT het tru A-scp. Mot stage tro vao layer chua ton tai, hoac
# vao layer co state RONG, se dung o chot chan "state RONG" cua
# buildspec - va thong bao o do noi ve SAI KHOA STATE chu khong noi rang
# layer chua duoc dung. Doc log do se dan nguoi ta di sua backend, dung
# cho khong hong.
#
# Nen ba bien duoi day khong phai co cho sang trong: chung la cach noi
# "layer nay da ton tai va da apply mot lan".
########################################




########################################
# STAGE Expiry
########################################

variable "expiry_blocks_pipeline" {
  description = <<-EOT
    Mot khoi `loosen` HET HAN co lam pipeline dung hay khong.

    false (mac dinh) = stage Expiry chi BAO CAO. Dung voi chu "bao cao"
    trong thiet ke, va dung voi mo ta cua lint.sh: che do --expiry sinh
    ra cho mot job chay theo lich, khong cho duong apply.

    NHUNG PHAI BIET DIEU NAY: mot stage khong bao gio that bai la mot
    stage khong ai doc ket qua. Neu de false thi phep thi hanh THAT phai
    nam o job drift hang dem - va phai co nguoi doc bao dong cua no.
    Khong co ca hai thi moi khoi loosen deu song vinh vien.

    true = het han thi dung pipeline. Chon cai nay khi khong chac co ai
    doc bao cao hang dem.
  EOT
  type        = bool
  default     = false
}

########################################
# HAI STAGE CUNG LAYER organization
#
# SCP, OU va tag policy nam cung mot layer va CUNG MOT STATE. Chung
# khong tach ra thanh ba layer - tach state la them hai lan init, hai
# khoa, va hai cho de lech. Tach o day la tach PHAM VI, bang -target va
# bang bang PHAM_VI trong ops-gate/gate.py.
########################################



########################################
# CONG DUYET - CHI O NHUNG STAGE CAN
########################################

variable "approve_stages" {
  description = <<-EOT
    Stage nao dung lai cho nguoi bam duyet TRUOC khi apply. Dung KHOA
    cua stage.

    Ten stage co the dung (xem local.stages_all trong main.tf):

      sec-ou   sec-scp   sec-tagging

    VI SAO KHONG PHAI MOI STAGE, VA CUNG KHONG PHAI KHONG STAGE NAO

    Cac stage khong nhu nhau o mot diem: thay doi sai co trieu chung hay
    khong.

      DNS record sai      co trieu chung ngay, co nguoi goi
      SCP sai             KHONG co trieu chung. Mot Deny bi go khong lam
                          gi "hong" - no chi lam mot viec truoc day bi
                          chan gio chay duoc
      permission set sai  mot group vao duoc mot account moi, co hieu luc
                          ngay, khong ai thay
      firewall rule sai   luu luong truoc day bi chan gio di qua, khong
                          co log nao noi mot luat vua bien mat

    Ba dong duoi la dung cho sec can doc. Dat cong duyet o moi stage se
    lam no bi bam theo phan xa - va mot cong bi bam theo phan xa la mot
    cong da ngung duoc doc.

    GO SAI TEN O DAY KHONG GAY LOI LUC CHAY: contains() tra ve false,
    stage do khong co cong duyet, pipeline chay binh thuong. Check
    "approve_stages_la_ten_that" bat viec do luc plan.
  EOT
  type        = list(string)
  default     = ["sec-scp"]
}

variable "approval_emails" {
  description = <<-EOT
    Dia chi nhan thu "co viec can duyet".

    MOI DIA CHI PHAI BAM XAC NHAN. Truoc khi bam, subscription o
    PendingConfirmation va KHONG nhan gi - ma Terraform van bao tao thanh
    cong. Nen mot cong duyet co topic, co subscription va khong ai duoc
    bao la mot cau hinh "dung" hoan toan.

    Kiem bang phep do, khong bang state:

      aws sns list-subscriptions-by-topic --topic-arn <arn> \
        --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output text
      # SubscriptionArn = "PendingConfirmation" -> chua bam

    Rong + approve_stages khong rong = check "co_cong_duyet_thi_co_nguoi_nhan"
    se keu: cong duyet se dung pipeline lai va khong ai duoc bao, roi het
    gio sau 7 ngay - va ket qua doc nhu pipeline bi treo.
  EOT
  type        = list(string)
  default     = []
}

########################################
# KHAI BAO CUA TUNG PIPELINE
#
# Bon bien duoi day la phan KHAC NHAU giua cac pipeline. Chung khong co
# mac dinh: mot mac dinh o day nghia la mot pipeline thieu khai bao van
# apply duoc, va no se apply mot tap rong hoac mot tap khong phai cua no.
########################################

variable "ten" {
  description = <<-EOT
    Hau to ten pipeline. Ten day du la "<project>-<ten>".

    PHAI duy nhat trong mot account: ten nay di vao ten pipeline, ten
    project CodeBuild, ten bucket artifact, ten log group va ten role.
    Hai caller cung `ten` se tranh nhau tung resource do, va thong bao
    dau tien la mot loi ve bucket da ton tai chu khong noi gi ve pipeline.

    Doi `ten` sau khi da apply se XOA ROI TAO LAI moi resource - ten la
    thuoc tinh khong sua tai cho duoc. `moved` block KHONG giup gi cho
    viec doi ten.
  EOT
  type        = string
}

variable "stages" {
  description = <<-EOT
    Cac stage cua pipeline nay, THEO THU TU CHAY.

    Thu tu den tu VI TRI trong danh sach, khong tu ten - xem loi 113.

    key            duy nhat TOAN CUC, va mang tien to chu so huu
                   (sec-, cloudops-). Bang PHAM_VI trong
                   ops-gate/gate.py la MOT ban dung chung cho moi
                   pipeline, nen hai pipeline cung mot key se de len nhau
                   trong bang do.
    layer          duong dan tu goc repo
    enabled        false = khong dua vao pipeline. Mot stage tro vao layer
                   chua ton tai hoac co state RONG se dung o chot chan
                   "state RONG" cua buildspec - va thong bao o do noi ve
                   SAI KHOA STATE chu khong noi rang layer chua duoc dung.
    targets        -target cho apply. Rong = ca layer.
    lint           lenh lint chay TRUOC plan, trong thu muc layer.
    khong_co_lint  ly do vi sao stage nay khong co lint. Phai co mot
                   trong hai - xem check "moi_stage_co_lint".
    mo_ta          hien trong noi dung thu duyet. Viet cho nguoi phai
                   quyet dinh luc 2 gio sang.
  EOT
  type = list(object({
    key           = string
    layer         = string
    enabled       = bool
    targets       = optional(list(string), [])
    lint          = optional(string, "")
    khong_co_lint = optional(string, "")
    mo_ta         = string
  }))
}

variable "catalogs" {
  description = <<-EOT
    Catalog nao duoc lint OFFLINE o stage dau, truoc moi layer.

    Lint offline khong can AWS, khong can state, khong can credential -
    do la ly do no chay duoc o dau pipeline. Mot loi schema o catalog cua
    layer THU BA phai dung pipeline TRUOC khi stage dau cham vao AWS.

    expiry rong = khong co che do bao cao het han cho catalog do.

    RONG LA HOP LE, nhung phai NOI RO bang var.khong_co_catalog. Rong ma
    im lang thi stage Lint chay 0 vong lap va van bao THANH CONG - mot
    cong kiem bao dat vi no khong kiem gi.
  EOT
  type = list(object({
    layer  = string
    ten    = string
    lint   = string
    expiry = optional(string, "")
  }))
  default = []
}

variable "khong_co_catalog" {
  description = <<-EOT
    Ly do pipeline nay KHONG co catalog nao de lint offline.

    Bat buoc khi var.catalogs rong. Khi do stage Lint va Expiry KHONG
    duoc tao - khong phai duoc tao roi bo qua.

    HAI VIEC KHAC NHAU, va cho nay tung lan:

      stage khong ton tai      khong ai doi no bao gi
      stage ton tai, khong lam gi  LUON xanh, va cai xanh do duoc doc
                               thanh "moi catalog deu sach"

    Hom nay chi layer organization co catalog (catalog/scp.yaml). Bon
    pipeline con lai chua co, nen chung khai ly do o day. Khi mot layer
    co catalog thi them vao var.catalogs va XOA dong nay.
  EOT
  type        = string
  default     = ""
}

########################################
# RANH GIOI GHI - KHAC NHAU O MOI PIPELINE
#
# Xem khoi "QUYEN CUA DICH VU" trong iam.tf.
########################################

variable "quyen_dich_vu" {
  description = <<-EOT
    Statement Allow cho dich vu ma pipeline nay quan. Dang IAM statement
    (object), se duoc noi vao policy cua role CodeBuild.

    Vi du cho pipeline SCP - xem landing-zone/ops-pipeline/main.tf.

    LUU Y VE PHAM VI: -target gioi han APPLY, con PLAN van refresh TOAN
    BO state cua layer. Nen o day phai co ca quyen DOC rong cho dich vu
    do, khong chi quyen ghi hep.
  EOT

  ####################################
  # `any`, KHONG PHAI `list(any)`
  #
  # list(any) buoc MOI PHAN TU phai cung mot type. IAM statement thi hop
  # le khi khac hinh:
  #
  #   mot statement co Condition, mot cai khong
  #   Action la ["a","b"] o cho nay, va concat(...) do dai chua biet o
  #   cho kia
  #   Resource la chuoi o cho nay, la danh sach o cho kia
  #
  # Terraform khong hop nhat duoc, va no bao:
  #
  #   Error: Invalid value for input variable
  #   element types must all match for conversion to list
  #
  # Mot thong bao noi ve "list" chu khong noi rang IAM statement khong
  # the cung hinh. Da vuong that o lan plan dau tien sau khi tach module.
  #
  # `any` khong hop nhat gi. Gia tri di thang vao jsonencode trong
  # iam.tf, va jsonencode nhan moi hinh.
  ####################################
  type    = any
  default = []
}

variable "tu_choi_dich_vu" {
  description = <<-EOT
    Statement Deny viet RO nhung viec pipeline nay khong duoc lam.

    Vi sao can, khi Allow da hep: Deny THANG Allow, nen mot Deny viet ro
    van chan duoc ke ca khi mot policy khac gan vao cung role mo rong
    hon. Va no DOC DUOC - mot nguoi doc danh sach Allow khong biet duoc
    thu gi CO Y khong cho.

    Rong la hop le, nhung hay tu hoi lai: mot pipeline khong co Deny nao
    la mot pipeline ma ranh gioi chi ton tai trong dau nguoi viet no.
  EOT

  # `any` chu khong list(any) - xem ly do o var.quyen_dich_vu.
  type    = any
  default = []
}
