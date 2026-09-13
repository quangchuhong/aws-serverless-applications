#!/usr/bin/env bash
#
# Doc lai LOG cua chinh lan chay pipeline vua roi, tim canh bao.
#
#   PIPELINE=<ten> ./kiem-log.sh
#
# Bien moi truong:
#   PIPELINE    ten pipeline (BAT BUOC - rong thi thoat 1, khong im lang)
#   LOG_GROUP   mac dinh /aws/codebuild/$PIPELINE
#   TU_THU_MUC  doc JSON co san, khong goi AWS - de test offline
#
# ======================================================================
# KHOANG TRONG MA KHONG LOP NAO KHAC DOC: CANH BAO
#
# Mot check block cua Terraform that bai, mot dong "Objects have changed
# outside of Terraform", mot canh bao cua provider - tat ca di qua ma
# stage van XANH. Va khong ai mo log cua mot build mau xanh.
#
# ======================================================================
# VI SAO O ops-gate/ CHU KHONG TRONG THU MUC MOT LAYER
#
# Cung ly do gate.py nam o day: phep kiem nay dung cho MOI pipeline van
# hanh. Sao chep no vao tung layer se cho ra ba ban roi bon ban, va ban
# lech se la ban LONG hon - vi khong ai sua mot phep kiem de no keu minh
# nhieu hon.
#
# buildspec-verify.yml goi no SAU lenh verify cua tung pipeline, va lay
# ma thoat cua ca hai. Nen mot pipeline co verify thi tu dong co ca phep
# kiem nay - khong phai khai them dong nao.
#
# ======================================================================
# LOC THEO EXECUTION, KHONG THEO CUA SO THOI GIAN
#
# Ban dau phep kiem nay quet ca log group trong 40 phut. No SAI ngay lan
# do dau: bat `Error: Saved plan is stale` cua mot luot TRUOC (luot bi
# superseded) roi bao LOI cho mot luot ma ca tam stage deu xanh.
#
# Cach chua khong phai rut ngan cua so - mot luot pipeline dai ~15 phut,
# khong co con so nao vua ca. La loc theo EXECUTION: buoc Verify nam
# TRONG execution do nen execution moi nhat chinh la no; tu danh sach
# action lay externalExecutionId dang "<project>:<build-uuid>", va
# build-uuid chinh la ten log stream.
#
set -uo pipefail

XANH=$'\033[32m'; DO=$'\033[31m'; VANG=$'\033[33m'; HET=$'\033[0m'

PIPELINE="${PIPELINE:-}"
LOG_GROUP="${LOG_GROUP:-${PIPELINE:+/aws/codebuild/$PIPELINE}}"
REGION="${AWS_REGION:-ap-southeast-1}"

D="${TU_THU_MUC:-}"
if [[ -z "$D" ]]; then
  D=$(mktemp -d)
  trap 'rm -rf "$D"' EXIT
  GOI_AWS=yes
else
  GOI_AWS=no
  echo "${VANG}Che do offline${HET}: doc JSON co san tu $D, KHONG goi AWS."
fi

########################################
# THIEU PIPELINE LA MOT LOI, KHONG PHAI "KHONG CO GI DE LAM"
#
# Bo qua trong im lang se lam mot pipeline khong bao gio duoc doc log ma
# van xanh - dung kieu hong ma ca phep kiem nay duoc viet ra de chan.
########################################
if [[ "$GOI_AWS" == "yes" && -z "$PIPELINE" ]]; then
  echo "${DO}LOI: thieu bien PIPELINE.${HET}"
  echo "     Khong biet doc log cua pipeline nao. Day KHONG phai 'khong co"
  echo "     canh bao nao' - la KHONG KIEM DUOC."
  echo "     codebuild.tf phai dat PIPELINE cho project verify."
  exit 1
fi

if [[ "$GOI_AWS" == "yes" ]]; then
  aws codepipeline list-pipeline-executions --pipeline-name "$PIPELINE" \
    --max-items 1 --region "$REGION" --output json > "$D/exec.json" 2>"$D/exec.err"

  EX=$(python3 - "$D/exec.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
s = d.get("pipelineExecutionSummaries") or []
print(s[0]["pipelineExecutionId"] if s else "")
PY
  )

  if [[ -z "$EX" ]]; then
    echo "${DO}LOI: khong doc duoc execution moi nhat cua $PIPELINE.${HET}"
    cat "$D/exec.err" 2>/dev/null | sed 's/^/     /'
    echo "     Day KHONG phai 'khong co canh bao nao'."
    exit 1
  fi

  echo "Pipeline  : $PIPELINE"
  echo "Execution : $EX"

  aws codepipeline list-action-executions --pipeline-name "$PIPELINE" \
    --filter "pipelineExecutionId=$EX" --region "$REGION" --output json \
    > "$D/action.json" 2>"$D/action.err"

  ####################################
  # MOT STREAM MOT LENH, KHONG DUNG filter-log-events
  #
  # filter-log-events co --log-stream-names, nhung khi mot stream khong
  # ton tai thi no tra ve loi cho CA lenh - va mot build bi superseded
  # truoc khi chay se khong co stream nao. Doc tung stream: mot cai thieu
  # chi lam mat cai do, khong lam mat ca phep quet.
  ####################################
  : > "$D/log.jsonl"
  for ST in $(python3 - "$D/action.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for a in d.get("actionExecutionDetails", []):
    eid = (a.get("output") or {}).get("executionResult", {}).get("externalExecutionId", "")
    if ":" in eid:
        print(eid.split(":", 1)[1])
PY
  ); do
    aws logs get-log-events --log-group-name "$LOG_GROUP" \
      --log-stream-name "$ST" --region "$REGION" --output json \
      >> "$D/log.jsonl" 2>>"$D/log.err" || true
  done
fi

########################################
# PHAN TICH
########################################
python3 - "$D" "${CODEBUILD_LOG_PATH:-}" <<'PY'
import json, os, re, sys

D = sys.argv[1]
# Stream log cua CHINH build nay. Loc theo execution chi lay stream cua
# action DA CO ket qua, va buoc Verify dang chay thi chua co - nen phep
# tru nay la du phong. GIU no: neu mot ngay CodePipeline bao cao action
# dang chay kem id, khong tru se lam script bat "CANH BAO" do chinh no in.
STREAM_TOI = sys.argv[2] if len(sys.argv) > 2 else ""

XANH, DO, VANG, HET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"

# Mau khop -> co phai canh bao MOI hay khong.
#
# "Resource targeting is in effect" va "Applied changes may be incomplete"
# la he qua truc tiep cua -target, tuc thiet ke cua cac pipeline nay. Bao
# chung moi lan la cach nhanh nhat lam nguoi ta thoi doc phan nay.
BIET_ROI = (
    "Resource targeting is in effect",
    "Applied changes may be incomplete",
    "The -target option is not for routine use",

    ####################################
    # KHUYEN NGHI dynamodb_table -> use_lockfile
    #
    # Xuat hien o MOI lan chay: buildspec truyen
    # -backend-config=dynamodb_table, va Terraform 1.11 khuyen dung
    # use_lockfile. Van chay binh thuong o 1.11.3.
    #
    # PHAI khop vao TIEU DE, khong khop vao dong noi ten tham so:
    # Terraform in canh bao thanh khung hai dong,
    #
    #   │ Warning: Deprecated Parameter
    #   │ The parameter "dynamodb_table" is deprecated. ...
    #
    # va dong thu hai bi la_ma_nguon() loc di nhu mot dong TIEP. Nen chuoi
    # duy nhat con de khop la tieu de - va tieu de khong noi tham so nao.
    #
    # He qua phai chap nhan: dong nay lam im MOI canh bao "Deprecated
    # Parameter", khong chi cai dynamodb_table. Hien chi co mot cai, da
    # kiem bang mat trong log.
    #
    # XOA DONG NAY khi ghim Terraform len nhanh 1.12+: luc do
    # dynamodb_table thanh loi that chu khong con la khuyen nghi.
    ####################################
    "Warning: Deprecated Parameter",
)

DANG_TIM = (
    "Warning:",
    "changed outside of Terraform",
    "CANH BAO",
    "Error:",
    "error occurred",
    "AccessDenied",
    "INSUFFICIENT_DATA",
)

NANG = ("Error:", "error occurred", "AccessDenied")


####################################
# DOC log.jsonl - MOT DOI TUONG JSON MOI KHOI
#
# Moi stream mot lan goi get-log-events, moi lan noi them mot doi tuong
# vao file. Nen day KHONG phai mot file JSON hop le - phai doc tung khoi.
#
# Va `aws` in JSON NHIEU DONG, nen khong tach duoc bang splitlines():
# dung raw_decode va nhay theo vi tri ket thuc.
####################################
def doc_log():
    p = os.path.join(D, "log.jsonl")
    err = ""
    pe = os.path.join(D, "log.err")
    if os.path.exists(pe):
        err = open(pe).read().strip()
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return None, err or "khong co file log.jsonl"
    t = open(p).read()
    de = json.JSONDecoder()
    ra, i = [], 0
    while i < len(t):
        while i < len(t) and t[i].isspace():
            i += 1
        if i >= len(t):
            break
        try:
            o, j = de.raw_decode(t, i)
        except Exception as ex:
            return None, err or f"log.jsonl hong o byte {i}: {ex}"
        ra += o.get("events") or []
        i = j
    return {"events": ra}, err


####################################
# BO DONG LA MA NGUON CUA LENH, KHONG PHAI KET QUA
#
# CodeBuild IN RA tung lenh truoc khi chay no. Nen mot dong nhu
#
#   echo "CANH BAO: ${SO_HONG} catalog co khoi `loosen` HET HAN."
#
# nam trong log o MOI lan chay - ke ca khi SO_HONG bang 0 va cau do khong
# bao gio duoc in. Khop vao cai `echo` SE in canh bao, chu khong vao canh
# bao.
#
# Da do: hai canh bao gia moi lan chay. Hai la du de nguoi ta thoi doc ca
# phan nay, tuc lop kiem nay tu vo hieu hoa.
#
# Cung ho voi viec externalExecutionSummary dan ca buildspec va doc nhu
# mot su co - thu phan biet duoc la HINH DANG cua dong, khong phai noi
# dung.
####################################
def la_ma_nguon(t):
    if t.startswith(("echo ", "printf ", "#")):
        return True

    # Dong TIEP cua mot khung canh bao Terraform: "│ <chi tiet>". Giu dong
    # DAU ("│ Warning: ..." / "│ Error: ...") vi do la dong mang noi dung;
    # bo phan con lai de mot canh bao khong bi dem thanh muoi dong.
    #
    # Viet bang if long chu khong dua vao thu tu uu tien and/or:
    # `a or b and c` la `a or (b and c)`, dung y nhung mot nguoi sua sau
    # se phai dung lai de nho quy tac do.
    if t.startswith("│ "):
        return "Warning:" not in t and "Error:" not in t

    return False


####################################
# BO MA MAU ANSI TRUOC KHI SO KHOP
#
# buildspec chay `terraform init` va `terraform plan` KHONG co -no-color,
# nen output Terraform trong log mang ma escape. Mot canh bao that ra la
#
#   \x1b[33m│\x1b[0m \x1b[1mWarning: \x1b[0m\x1b[1mDeprecated Parameter\x1b[0m
#
# Nen "Warning: Deprecated Parameter" KHONG con la chuoi con lien mach -
# co ma escape chen giua. Con "Warning:" thi van lien, nen no khop.
#
# Ket qua: dong do bi bat boi DANG_TIM ma KHONG bi BIET_ROI loc, va no
# hien ra o moi lan chay.
#
# VI SAO KHONG THAY SOM: `aws logs tail` in ra terminal, va terminal DIEN
# GIAI cac ma do - nen chung vo hinh. Thu nguoi doc thay la mot dong sach
# se, giong het chuoi trong BIET_ROI. Cung ho voi hai lan truoc trong
# buoi nay: CodeBuild in ma nguon cua lenh, va externalExecutionSummary
# dan ca buildspec - MAN HINH lam hai thu khac nhau trong giong nhau.
#
# Cach chua khac hai lan do: o day khong phai loc theo hinh dang, ma la
# CHUAN HOA truoc khi so. `-no-color` trong buildspec cung chua duoc,
# nhung do la sua o mot cho khac va khong giup cho nhung log da co.
####################################
ANSI = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")


def sach(t):
    return ANSI.sub("", t)


print()
print("── Log cua lan chay vua roi")

d, e = doc_log()
if d is None:
    print(f"  {DO}LOI{HET}  KHONG doc duoc log cua lan chay.")
    print(f"        {e}")
    print("        Day KHONG phai 'khong co canh bao nao'. Thieu quyen thi them")
    print("        logs:GetLogEvents va codepipeline:ListActionExecutions cho")
    print("        role CodeBuild.")
    sys.exit(1)

su_kien = [
    x for x in (d.get("events") or [])
    if x.get("logStreamName") != STREAM_TOI
]

####################################
# DONG TIEP CUA MOT KHUNG CANH BAO MANG CA NOI DUNG
#
# Terraform in mot check block that bai thanh HAI dong:
#
#   │ Warning: Check block assertion failed
#   │ Pham vi RONG nen khong sinh assignment nao: analytics . ...
#
# la_ma_nguon() bo dong thu hai - dung, de mot canh bao khong bi dem
# thanh muoi dong. Nhung voi RIENG check block, dong thu hai la CA noi
# dung: "Check block assertion failed" khong noi check NAO that bai, va
# mot layer co the co hang chuc check.
#
# Da do that: lan chay ops-permission-set dau tien bao dung mot dong
#
#     │ Warning: Check block assertion failed
#
# va tu dong do khong the biet duoc rang pham vi "analytics" dang rong,
# tuc ba permission set dang cap phat vao 0 account. Bao cao chi ra
# "co mot cai gi do sai" la mot bao cao KHONG dung duoc - nguoi doc phai
# mo log tay, tuc dung cai viec lop nay duoc viet ra de khoi phai lam.
#
# Nen: khop o dong DAU, roi KEO THEO may dong tiep lam chi tiet.
####################################
def chi_tiet(i):
    """May dong '│ ...' ngay sau dong i, trong CUNG mot stream.

    ---------------------------------------------------------------------
    CUA SO PHAI DU RONG - 4 DONG LA KHONG DU

    Ban dau ham nay lay 4 dong. Lan chay that cho ra:

        on assignments.tf line 119, in check "declared_scopes_not_empty":
        119:     condition = length(local.empty_scopes) == 0

    Ten check la phan quan trong nhat va no co - nhung error_message, dong
    noi PHAM VI NAO dang rong, nam ngoai cua so. Khung that cua Terraform
    dai hon nhieu:

        │ Warning: Check block assertion failed
        │
        │   on assignments.tf line 119, in check "...":
        │   119:     condition = ...
        │     ├────────────────
        │     │ local.empty_scopes is list of string with 1 element
        │
        │ Pham vi RONG nen khong sinh assignment nao: analytics . ...
        ╵

    Nen: doc toi khi khung dong (dong khong bat dau bang '│' - ke ca '╵'),
    bo khung trang tri va khoi gia tri long ben trong, roi lay dong 'on ...'
    CONG hai dong cuoi. error_message luon o cuoi khung.

    Gioi han 30 dong de mot khung di thuong khong keo ca log vao.
    """
    tho = []
    goc = su_kien[i].get("logStreamName")
    for j in range(i + 1, min(i + 30, len(su_kien))):
        # Hai stream duoc noi duoi nhau trong su_kien, nen khong chan o
        # day thi cuoi stream nay se keo dong dau cua stream sau vao.
        if su_kien[j].get("logStreamName") != goc:
            break
        t = sach(su_kien[j].get("message") or "").strip()
        if not t.startswith("│"):
            break
        t = t.lstrip("│").strip()
        if t:
            tho.append(t)

    # Sau khi bo '│' NGOAI, khoi gia tri long van con '│' cua no - do la
    # cach phan biet duoc, khong phai doan theo noi dung.
    con = [t for t in tho if not t.startswith(("├", "└", "│"))]
    if not con:
        return tho[:2]

    ra = [t for t in con if t.startswith("on ")][:1]
    for t in con[-2:]:
        if t not in ra:
            ra.append(t)
    return ra


####################################
# BO PHAN OUTPUT CUA TERRAFORM - VAN BAN TAI LIEU, KHONG PHAI KET QUA
#
# Lan chay dau cua ops-config-rules bao BON canh bao, va ca bon la gia:
#
#   CANH BAO  2 dong
#     CHUA BAM LINK = KHONG NHAN DUOC CANH BAO NAO.
#   INSUFFICIENT_DATA  2 dong
#     Rule o trang thai INSUFFICIENT_DATA nghia la recorder KHONG ghi
#
# Ca hai chuoi nam trong landing-zone/config-detective/outputs.tf, tuc la
# van ban TAI LIEU trong mot `output` cua Terraform. `plan` in no mot lan,
# `apply` in lan nua - nen dung 2 dong moi cai.
#
# Day la CUA THU TU cua cung mot lop loi trong buoi nay:
#
#   1. CodeBuild in ma nguon cua tung lenh -> mot `echo "CANH BAO: ..."`
#      nam trong log ke ca khi cau do khong bao gio duoc in
#   2. externalExecutionSummary dan ca buildspec vao nhu mot su co
#   3. ma ANSI cat "Warning: Deprecated Parameter" thanh khong lien mach
#   4. output cua Terraform chua chinh nhung tu ma phep kiem nay di tim
#
# Va cai thu tu co mot chieu tro treu rieng: chuoi MO TA mot van de bi bat
# nhu chinh van de do. Cang viet tai lieu ky cang nhieu duong tinh gia.
#
# VI SAO KHONG THEM HAI CHUOI DO VAO BIET_ROI: do la danh whack-a-mole -
# va ta se giet luon tin hieu THAT. Mot rule that o trang thai
# INSUFFICIENT_DATA la dieu can biet; van ban noi VE trang thai do thi
# khong.
#
# Nen phan biet bang HINH DANG, nhu la_ma_nguon(): noi dung HEREDOC
# (`x = <<EOT ... EOT`, hoac `+ x = <<-EOT ... EOT` trong ban plan) khong
# bao gio chua ket qua that. Ca bon dong gia deu nam trong dung mot khoi
# nhu vay.
#
# =======================================================================
# VA MOT CACH LOC DA THU ROI BO: "bo het phan sau `Outputs:`"
#
# Ban dau cho nay con bo moi dong sau khi gap `Outputs:`, voi ly do
# "canh bao cua Terraform in TRUOC output, khong bao gio sau". Ly do do
# SAI, va no lam MAT mot canh bao that ngay lan chay sau:
#
#   2385: Outputs:                               <- bat o day
#   2449: next_steps = <<EOT
#   2490: EOT
#   2839: │ Warning: Check block assertion failed <- va nuot mat dong nay
#   2853: Outputs:
#
# buildspec chay HAI lenh apply trong cung mot build (`apply tfplan` roi
# `apply -refresh-only`), nen `Outputs:` xuat hien GIUA stream chu khong
# o cuoi. Mot canh bao sinh ra giua hai lan apply nam sau khoi output
# thu nhat.
#
# Hai dieu dang giu lai tu lan do:
#
#   1. Loc theo heredoc MOT MINH la du - ca bon dong gia deu nam trong
#      heredoc. Khoi `Outputs:` khong bat them gi, chi bo bot.
#   2. Cach phat hien ra: SO SANH CON SO. Bao cao sau khi sua ra "0 canh
#      bao" tren dung 1711 dong log nhu luot truoc, trong khi luot truoc
#      ra 2 - va mot trong hai la phat hien that. Neu chi doc mau xanh
#      thi mot lop kiem vua bi lam im se di qua nhu mot thanh cong.
#
# Trang thai phai reset theo STREAM: su_kien noi cac stream duoi nhau.
####################################
thay = {}
stream_truoc = None
trong_heredoc = False

for i, x in enumerate(su_kien):
    st = x.get("logStreamName")
    if st != stream_truoc:
        stream_truoc = st
        trong_heredoc = False

    t = sach(x.get("message") or "").strip()

    if trong_heredoc:
        if t in ("EOT", "EOT,"):
            trong_heredoc = False
        continue
    if t.endswith("<<-EOT") or t.endswith("<<EOT"):
        trong_heredoc = True
        continue

    if any(b in t for b in BIET_ROI):
        continue
    if la_ma_nguon(t):
        continue
    ####################################
    # GOM DONG TRUNG - MOT PHAT HIEN, KHONG PHAI HAI
    #
    # Lan chay that cua pipeline ops bao "2 dong canh bao", va ca hai la
    # CUNG mot check:
    #
    #   │ Warning: Check block assertion failed
    #     on tag-policy.tf line 136, in check "tag_policy_is_report_only":
    #   │ Warning: Check block assertion failed
    #     on tag-policy.tf line 136, in check "tag_policy_is_report_only":
    #
    # buildspec chay `plan` roi `apply`, va check block duoc danh gia o CA
    # HAI - nen moi phat hien xuat hien dung hai lan. Con so 2 lam nguoi
    # doc di tim hai thu trong khi chi co mot.
    #
    # Gom theo (dong, chi tiet) va dem: hai lan cung mot check thanh "x2",
    # con hai check KHAC nhau van la hai muc rieng. Cung ly do gom canh
    # bao loai tru trong kiem-config.sh.
    ####################################
    for mau in DANG_TIM:
        if mau in t:
            khoa = (t[:160], tuple(chi_tiet(i)))
            d = thay.setdefault(mau, {})
            d[khoa] = d.get(khoa, 0) + 1
            break

print(f"    {len(su_kien)} dong log")

if not su_kien:
    print(f"  {DO}LOI{HET}  doc duoc stream cua execution nhung KHONG co dong log nao.")
    print("        Doc duoc va rong la mot cau tra loi hop le - nhung o day no kho")
    print("        tin: buoc Verify chay SAU cac stage apply, nen log cua chung phai")
    print("        con. Kiem lai ten log group va region.")
    sys.exit(1)

if not thay:
    print(f"    {XANH}Khong co canh bao nao{HET} ngoai nhung dong biet roi.")
    sys.exit(0)

# In SO PHAT HIEN (so muc rieng), va so dong o trong ngoac khi chung khac
# nhau. Hai con so tra loi hai cau hoi khac nhau: "co bao nhieu thu phai
# xem" va "no xuat hien bao nhieu lan".
def so_dong(d):
    return sum(d.values())


for mau, d in sorted(thay.items(), key=lambda kv: -so_dong(kv[1])):
    n, tong = len(d), so_dong(d)
    dem = f"{n} phat hien" + (f" / {tong} dong" if tong != n else "")
    print(f"    {VANG}{mau}{HET}  {dem}")
    for (t, ct), lan in sorted(d.items(), key=lambda kv: -kv[1])[:3]:
        print(f"      {t}" + (f"   (x{lan})" if lan > 1 else ""))
        for c in ct[:3]:
            print(f"        {c[:200]}")
    if n > 3:
        print(f"      ... con {n - 3} phat hien nua")

nang = [m for m in thay if m in NANG]
print()
if nang:
    print(f"  {DO}LOI{HET}  log cua lan chay co dong bao LOI ({', '.join(nang)}) du stage")
    print("        van xanh. Doc log truoc khi tin ket qua.")
    sys.exit(1)

print(f"  {VANG}CANH BAO{HET} log co {sum(len(v) for v in thay.values())} phat hien "
      f"({', '.join(sorted(thay))}).")
print("        Stage xanh khong co nghia la khong co gi.")
sys.exit(0)
PY
