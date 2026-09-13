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
import json, os, sys

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

thay = {}
for x in su_kien:
    t = (x.get("message") or "").strip()
    if any(b in t for b in BIET_ROI):
        continue
    if la_ma_nguon(t):
        continue
    for mau in DANG_TIM:
        if mau in t:
            thay.setdefault(mau, []).append(t[:160])
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

for mau, ds in sorted(thay.items(), key=lambda kv: -len(kv[1])):
    print(f"    {VANG}{mau}{HET}  {len(ds)} dong")
    for t in ds[:3]:
        print(f"      {t}")
    if len(ds) > 3:
        print(f"      ... con {len(ds) - 3} dong nua")

nang = [m for m in thay if m in NANG]
print()
if nang:
    print(f"  {DO}LOI{HET}  log cua lan chay co dong bao LOI ({', '.join(nang)}) du stage")
    print("        van xanh. Doc log truoc khi tin ket qua.")
    sys.exit(1)

print(f"  {VANG}CANH BAO{HET} log co {sum(len(v) for v in thay.values())} dong canh bao "
      f"({', '.join(sorted(thay))}).")
print("        Stage xanh khong co nghia la khong co gi.")
sys.exit(0)
PY
