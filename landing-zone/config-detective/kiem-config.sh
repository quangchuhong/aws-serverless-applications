#!/usr/bin/env bash
#
# Kiem ORGANIZATION CONFIG RULE dang that o AWS - khong doc Terraform state.
#
#   ./kiem-config.sh [arn-role-de-assume]
#
# TU_THU_MUC=<dir> de doc JSON co san (test offline).
#
# PHEP KIEM LOG KHONG O DAY: no chung cho moi pipeline nen nam o
# ../ops-gate/kiem-log.sh, va buildspec-verify.yml goi no LUON sau lenh nay.
#
# ======================================================================
# VI SAO CAN, KHI LY DO khong_co_verify TRUOC DAY NGHE CO LY
#
# Truoc day cho nay khai khong_co_verify voi ly do hai phan:
#
#   1. "organization config rule song o account delegated admin; hoi tu
#      management tra ve NoSuchOrganizationConfigRuleException"
#   2. "trang thai tuan thu can toi mot gio, ket qua dau thuong la
#      INSUFFICIENT_DATA - do la phep do theo lich, khong phai phep do
#      sau apply"
#
# Phan 2 la THAT, va no van that. Nhung no chi dung cho TUAN THU. De mot
# phep do co do tre phu quyet ca buoc verify la dung cai loi da mac o
# ops-trail (nơi "phai doi 2 phut cho lo log dau" da giet luon nam thuoc
# tinh doc duoc ngay). Nhung thu sau day KHONG theo lich:
#
#   rule co ton tai khong                doc duoc ngay
#   ExcludedAccounts co ai moi khong     doc duoc ngay
#   rule da rai xuong tung account chua  doc duoc ngay (DetailedStatus)
#
# Cai thu hai la thu gate.py canh (tap_khong_lon): moi account them vao
# ExcludedAccounts la mot account THOAT khoi phep kiem, va no thoat trong
# im lang - rule van "dang bat", console van hien xanh.
#
# Phan 1 thi toi KHONG kiem chung duoc, va do la ly do script nay doc qua
# DUNG CAI CUA MA apply da dung: cung role assume sang account security.
# Doc qua cua khac roi khong thay gi se cho ra "0 rule", va 0 co the co
# nghia la "chua apply" hay "hoi sai account" - hai viec khac han nhau.
# Nen o day khong doan: nhan ARN role, assume, va IN RA dang doc bang
# danh tinh nao.
#
# ======================================================================
# CAI KHONG KIEM O DAY - NOI RO, KHONG DE MAU XANH TU NOI HO
#
# TRANG THAI TUAN THU (COMPLIANT / NON_COMPLIANT). Config danh gia theo
# lich; ngay sau apply gan nhu luon la INSUFFICIENT_DATA, va do KHONG
# phai loi. Bat no o day se cho ra mot buoc verify do moi lan, tuc mot
# buoc verify bi tat sau hai tuan.
#
# Phep do do thuoc mot lop khac: aggregator + duong bao dong trong
# notify.tf, doc theo ngay chu khong theo lan apply.
#
set -uo pipefail

XANH=$'\033[32m'; DO=$'\033[31m'; VANG=$'\033[33m'; HET=$'\033[0m'

ARN_ROLE="${1:-}"
if [[ $# -gt 1 ]]; then
  echo "Script nay nhan toi da mot tham so (ARN role). Nhan duoc: $*"
  exit 2
fi

D="${TU_THU_MUC:-}"
if [[ -z "$D" ]]; then
  D=$(mktemp -d)
  trap 'rm -rf "$D"' EXIT
  GOI_AWS=yes
else
  GOI_AWS=no
  echo "${VANG}Che do offline${HET}: doc JSON co san tu $D, KHONG goi AWS."
fi

REGION="${AWS_REGION:-ap-southeast-1}"

if [[ "$GOI_AWS" == "yes" ]]; then
  ####################################
  # ASSUME - DOC QUA DUNG CUA MA apply DA DUNG
  #
  # Khong assume thi doc bang danh tinh CodeBuild o management, va neu
  # management khong thay rule cua delegated admin thi ket qua la "0
  # rule" - mot con so trong giong het "layer chua duoc apply".
  #
  # RONG thi van chay, nhung phan phan tich se noi ro la dang doc tu
  # management va 0 rule se thanh LOI chu khong thanh mau xanh.
  ####################################
  if [[ -n "$ARN_ROLE" ]]; then
    aws sts assume-role --role-arn "$ARN_ROLE" \
      --role-session-name verify-config --region "$REGION" \
      --output json > "$D/assume.json" 2>"$D/assume.err"

    # Credential KHONG duoc in ra: `read` nuot stdout cua subshell, va
    # khong dong nao duoi day echo lai chung.
    read -r AK SK ST <<<"$(python3 - "$D/assume.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
c = d.get("Credentials") or {}
if c:
    print(c["AccessKeyId"], c["SecretAccessKey"], c["SessionToken"])
PY
    )"

    if [[ -z "${AK:-}" ]]; then
      echo "${DO}LOI: khong assume duoc sang $ARN_ROLE.${HET}"
      sed 's/^/     /' "$D/assume.err" 2>/dev/null
      echo "     Day KHONG phai 'khong co gi sai' - la KHONG KIEM DUOC."
      exit 1
    fi
    export AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$ST"
  fi

  aws sts get-caller-identity --region "$REGION" --output json \
    > "$D/who.json" 2>"$D/who.err"

  aws configservice describe-organization-config-rules --region "$REGION" \
    --output json > "$D/rules.json" 2>"$D/rules.err"

  for R in $(python3 - "$D/rules.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for r in d.get("OrganizationConfigRules", []):
    print(r["OrganizationConfigRuleName"])
PY
  ); do
    aws configservice get-organization-config-rule-detailed-status \
      --organization-config-rule-name "$R" --region "$REGION" --output json \
      > "$D/status-$R.json" 2>"$D/status-$R.err"
  done
fi

########################################
# PHAN TICH
########################################
python3 - "$D" "${ARN_ROLE:-}" <<'PY'
import json, os, sys

D = sys.argv[1]
ARN_ROLE = sys.argv[2] if len(sys.argv) > 2 else ""
XANH, DO, VANG, HET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"
loi, canh = [], []


def doc(ten):
    """(du_lieu, loi). PHAI tra ve ca hai - "rong", "AWS bao loi" va "JSON
    hong" la ba viec khac nhau, va hai cai sau KHONG duoc thanh mau xanh."""
    p = os.path.join(D, ten)
    err = ""
    pe = p.rsplit(".json", 1)[0] + ".err"
    if os.path.exists(pe):
        err = open(pe).read().strip()
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return None, err or f"khong co file {ten}"
    try:
        return json.load(open(p)), ""
    except Exception as e:
        return None, err or f"{ten} khong phai JSON: {e}"


print()
print("── Dang doc bang danh tinh nao")
d, e = doc("who.json")
if d is None:
    print(f"  {VANG}khong doc duoc get-caller-identity{HET}: {e}")
else:
    print(f"    account  {d.get('Account')}")
    print(f"    arn      {d.get('Arn')}")
print(f"    assume   {ARN_ROLE or 'KHONG - doc truc tiep bang danh tinh CodeBuild'}")

####################################
# 1. RULE CO TON TAI KHONG
#
# 0 rule KHONG duoc thanh mau xanh. Doc duoc va rong la mot cau tra loi
# hop le, nhung o day no co ba nghia khac han nhau: layer chua apply, hoi
# sai account, hoac ai do vua xoa het rule. Ca ba deu phai lam stage do.
####################################
print()
print("── Organization config rule")
d, e = doc("rules.json")
rules = []
if d is None:
    loi.append(
        "khong doc duoc describe-organization-config-rules.\n"
        f"        {e}"
    )
else:
    rules = d.get("OrganizationConfigRules") or []
    if not rules:
        loi.append(
            "0 organization config rule. Doc duoc va RONG - nen day khong phai\n"
            "        loi doc, va cung khong phai 'khong co gi sai'. Ba nghia khac han:\n"
            "          - layer config-detective chua duoc apply\n"
            "          - dang hoi SAI account (rule song o delegated admin; thu\n"
            "            truyen ARN role sang account security lam tham so)\n"
            "          - rule da bi xoa het"
        )

ngoai_le_theo_tap = {}

for r in sorted(rules, key=lambda x: x["OrganizationConfigRuleName"]):
    ten = r["OrganizationConfigRuleName"]
    md = r.get("OrganizationManagedRuleMetadata") or {}
    ngoai_le = r.get("ExcludedAccounts") or []

    ds, e1 = doc(f"status-{ten}.json")
    if ds is None:
        trang_thai = {}
        loi.append(f"khong doc duoc trang thai trien khai cua rule {ten}.\n        {e1}")
    else:
        trang_thai = {}
        for s in ds.get("OrganizationConfigRuleDetailedStatus") or []:
            trang_thai[s.get("MemberAccountRuleStatus", "?")] = (
                trang_thai.get(s.get("MemberAccountRuleStatus", "?"), 0) + 1
            )

    ####################################
    # RuleIdentifier, KHONG PHAI SourceIdentifier
    #
    # Lan chay that dau tien in "?" o ca 10 rule. Nguyen nhan: khoa cua API
    # la RuleIdentifier, con SourceIdentifier la ten truong o phia
    # Terraform (va o describe-config-rules, tuc rule TUNG ACCOUNT).
    #
    # Va cai "?" do khong lam gi do het - no chi la mot dau hoi in ra muoi
    # lan. Dung lop loi ghi day trong repo nay: mot phep doc that bai tra
    # ve rong, va rong duoc doc thanh cau tra loi. Nen giu ca hai khoa va
    # noi RO khi khong doc duoc, thay vi in mot ky tu.
    ####################################
    ma_rule = md.get("RuleIdentifier") or md.get("SourceIdentifier") or ""
    if not ma_rule:
        ma_rule = "KHONG DOC DUOC RuleIdentifier - xem OrganizationManagedRuleMetadata"

    so_gan = sum(trang_thai.values())
    tom = ", ".join(f"{k}={v}" for k, v in sorted(trang_thai.items())) or "khong co so lieu"
    print(f"    {ten}")
    print(f"        {ma_rule}")
    print(f"        {so_gan} duoc kiem, {len(ngoai_le)} loai tru  |  {tom}")

    ####################################
    # 2. ExcludedAccounts - TAP LON LEN LA NOI LONG
    #
    # Cai nay nguoc truc giac nen phai bao ro: moi account trong danh sach
    # nay la mot account THOAT khoi phep kiem, va no thoat trong im lang -
    # rule van "dang bat", console van hien xanh. gate.py canh dung viec
    # nay (tap_khong_lon), nhung gate.py doc BAN PLAN; neu ai do them bang
    # tay o console thi khong co ban plan nao de doc.
    #
    # CANH BAO chu khong LOI: mot ngoai le co the la co y va da duyet.
    # Cai sai la ngoai le KHONG AI BIET.
    ####################################
    ####################################
    # GOM THEO TAP LOAI TRU, KHONG BAO MOI RULE MOT LAN
    #
    # Lan chay that dau tien in MUOI doan y het nhau - ca 10 rule cung loai
    # tru dung 7 account do. Muoi doan trung khit la cach nhanh nhat lam
    # nguoi ta thoi doc ca phan nay, tuc lop kiem tu vo hieu hoa. Cung ly
    # do BIET_ROI ton tai trong kiem-log.sh.
    #
    # Va gom lai con noi duoc mot dieu ma bao rieng tung rule khong noi
    # duoc: "CUNG MOT tap 7 account thoat khoi CA 10 rule" la mot cau ve
    # chinh sach, con "rule X loai tru 7 account" mười lần thì không.
    ####################################
    if ngoai_le:
        ngoai_le_theo_tap.setdefault(tuple(sorted(ngoai_le)), []).append(ten)

    ####################################
    # 3. TRIEN KHAI - KHAC TUAN THU, VA KHONG THEO LICH
    #
    # FAILED o day nghia la rule KHONG TON TAI trong account do, tuc account
    # do khong duoc kiem gi ca. Do la phep do tuc thi, doc duoc ngay sau
    # apply - khong lien quan gi den do tre cua danh gia tuan thu.
    ####################################
    xau = {k: v for k, v in trang_thai.items() if "FAILED" in k}
    if xau:
        loi.append(
            f"rule {ten} trien khai THAT BAI o mot so account: "
            f"{', '.join(f'{k}={v}' for k, v in sorted(xau.items()))}.\n"
            "        FAILED nghia la rule KHONG ton tai trong account do - account do\n"
            "        khong duoc kiem gi ca, va console cua to chuc van hien rule xanh.\n"
            "        Doc chi tiet:\n"
            f"          aws configservice get-organization-config-rule-detailed-status \\\n"
            f"            --organization-config-rule-name {ten}"
        )

    dang_chay = {k: v for k, v in trang_thai.items() if "IN_PROGRESS" in k}
    if dang_chay:
        canh.append(
            f"rule {ten} con dang trien khai: "
            f"{', '.join(f'{k}={v}' for k, v in sorted(dang_chay.items()))}.\n"
            "        Chua that bai, nhung cung chua xong - chay lai phep kiem nay sau\n"
            "        vai phut de biet ket qua."
        )

####################################
# MOT CANH BAO CHO MOI TAP LOAI TRU
#
# Lan chay that dau tien cho ra MUOI doan y het nhau. Gom lai con noi duoc
# mot dieu ma bao rieng tung rule khong noi duoc: cung MOT tap account
# thoat khoi CA danh sach rule la mot cau ve chinh sach, khong phai mot su
# co cua tung rule.
####################################
for tap, ten_rule in sorted(ngoai_le_theo_tap.items(), key=lambda kv: -len(kv[1])):
    chung = "CA %d rule" % len(ten_rule) if len(ten_rule) == len(rules) else "%d rule" % len(ten_rule)
    canh.append(
        f"{chung} dang loai tru cung MOT tap {len(tap)} account:\n"
        f"          {', '.join(tap)}\n"
        f"        Rule: {', '.join(ten_rule)}\n"
        "        Moi account o day THOAT khoi phep kiem, va thoat trong im lang -\n"
        "        rule van 'dang bat' va console van hien xanh. gate.py canh viec nay\n"
        "        khi no di qua ban plan, nhung mot lan them bang tay o console thi\n"
        "        khong co ban plan nao de doc.\n"
        "        DOI CHIEU voi excluded_accounts trong tfvars cua config-detective:\n"
        "          grep -A 20 excluded_accounts ../config-detective/terraform.tfvars\n"
        "        Lech nghia la co nguoi sua ngoai Terraform."
    )

####################################
# CAI KHONG KIEM - NOI RO
####################################
print()
print("  Script nay KHONG kiem TRANG THAI TUAN THU (COMPLIANT/NON_COMPLIANT):")
print("  Config danh gia theo LICH, nen ngay sau apply gan nhu luon la")
print("  INSUFFICIENT_DATA va do khong phai loi. Bat no o day se cho ra mot buoc")
print("  verify do moi lan, tuc mot buoc verify bi tat sau hai tuan. Phep do do")
print("  thuoc lop khac: aggregator va duong bao dong trong notify.tf.")

print()
for c in canh:
    print(f"  {VANG}CANH BAO{HET} {c}")
for l in loi:
    print(f"  {DO}LOI{HET}  {l}")

print()
print(f"  Da kiem: {len(rules)} organization config rule.")
if loi:
    print(f"  {DO}{len(loi)} loi{HET}, {len(canh)} canh bao.")
    sys.exit(1)
if canh:
    print(f"  {VANG}{len(canh)} canh bao{HET}, 0 loi.")
    sys.exit(0)
print(f"  {XANH}Moi rule ton tai, khong ngoai le, trien khai xong.{HET} 0 canh bao.")
PY
