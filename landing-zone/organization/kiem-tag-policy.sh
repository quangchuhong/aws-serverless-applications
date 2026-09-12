#!/usr/bin/env bash
#
# Kiem tag policy DANG THAT o AWS, khong qua Terraform state.
#
#   ./kiem-tag-policy.sh
#
# Chay sau khi pipeline qh11-lz-ops apply xong stage sec-tagging.
#
# ======================================================================
# VI SAO CAN, KHI `terraform output tag_policy` DA IN enabled = true
#
# output do doc STATE. State noi rang Terraform DA GOI CreatePolicy va
# AWS tra ve 200 - no khong noi policy dang gan vao dau, noi dung con
# dung khong, hay no co chan gi khong.
#
# Voi tag policy thi khoang cach giua hai dieu do rong hon binh thuong,
# vi mot policy DUNG NOI DUNG van chan dung 0 thu khi enforced_for rong.
# Xem nhat ky loi 126: cung sai biet do o SCP mat mot lan goi API bi tu
# choi moi do duoc.
#
# ======================================================================
# BA TANG, VA SCRIPT NAY CHI DO TANG THU NHAT
#
#   tag policy           ep DUNG CACH VIET va GIA TRI hop le  <- o day
#   SCP                  chan TAO resource khi thieu tag
#   Config required-tags PHAT HIEN resource da co ma thieu tag
#
# Nhac lai dieu hay bi hieu nham nhat: tag policy KHONG lam tag tro
# thanh bat buoc. No chi quan ly GIA TRI cua mot tag KHI tag do duoc
# gan. Mot EC2 instance khong co tag nao ca thi no khong noi gi het, ke
# ca da bat enforced_for.
#
# ======================================================================
# GOI AWS RA FILE, ROI MOT KHOI PYTHON DOC HET
#
# Khong phai cho gon: cach nay lam moi phep phan tich CHAY DUOC OFFLINE
# voi file JSON dung san, nen logic doc ket qua duoc thu ma khong can
# credential. Ban dau script nay dung `python3 -c` long trong vong lap
# bash, va no chua bao gio chay duoc lan nao - backslash trong bieu thuc
# f-string la SyntaxError o Python < 3.12.
#
#   TU_THU_MUC=/duong/dan ./kiem-tag-policy.sh   doc file co san, khong goi AWS
#
set -uo pipefail

XANH=$'\033[32m'; DO=$'\033[31m'; VANG=$'\033[33m'; HET=$'\033[0m'

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

########################################
# CHAN CHAY NHAM ACCOUNT
#
# Organizations chi tra loi tu ACCOUNT MANAGEMENT. Goi tu account khac
# thi moi lenh duoi day tra ve AccessDeniedException hoac rong - va mot
# script doc "rong" thanh "khong co tag policy nao" se bao mot su co
# khong co that.
#
# Cung ho voi loi 48 va 57 o network/verify.sh: mot phep do dung, tra
# loi cho mot cau hoi khac.
########################################
if [[ "$GOI_AWS" == "yes" ]]; then
  ACTUAL=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
  if [[ -z "$ACTUAL" ]]; then
    echo "${DO}Khong goi duoc sts:GetCallerIdentity${HET} - chua co credential?"
    exit 1
  fi

  MASTER=$(aws organizations describe-organization \
    --query Organization.MasterAccountId --output text 2>&1)
  if [[ "$MASTER" != [0-9]* ]]; then
    echo "${DO}Khong doc duoc describe-organization${HET}"
    echo "  $MASTER"
    echo
    echo "Day KHONG phai 'to chuc khong ton tai'. Organizations chi tra loi"
    echo "tu account MANAGEMENT. Dang dung: $ACTUAL"
    exit 1
  fi

  if [[ "$ACTUAL" != "$MASTER" ]]; then
    echo "${DO}Sai account${HET}"
    echo "  dang dung  : $ACTUAL"
    echo "  management : $MASTER"
    echo
    echo "Moi lenh Organizations se tra ve rong hoac AccessDenied, va script"
    echo "se bao mot su co khong co that. Doi credential roi chay lai."
    exit 1
  fi

  echo
  echo "Account management : $ACTUAL"
  echo "Vung               : $REGION"

  ########################################
  # GOI. Loi cua AWS duoc GHI VAO FILE chu khong bi vut di: khoi python
  # phan biet "doc duoc va rong" voi "khong doc duoc", va no chi lam
  # duoc dieu do neu con thay thong bao loi.
  ########################################
  aws organizations list-roots --output json                            > "$D/roots.json"  2>"$D/roots.err"
  aws organizations list-policies --filter TAG_POLICY --output json     > "$D/policies.json" 2>"$D/policies.err"

  for PID in $(python3 - "$D/policies.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for p in d.get("Policies", []):
    print(p["Id"])
PY
  ); do
    aws organizations describe-policy --policy-id "$PID" \
      --query 'Policy.Content' --output text        > "$D/noidung-$PID.json" 2>"$D/noidung-$PID.err"
    aws organizations list-targets-for-policy --policy-id "$PID" --output json \
                                                   > "$D/target-$PID.json"  2>"$D/target-$PID.err"
  done

  aws resourcegroupstaggingapi get-compliance-summary --group-by TARGET_ID \
    --region "$REGION" --output json                > "$D/tuanthu.json" 2>"$D/tuanthu.err"

  aws resourcegroupstaggingapi get-resources --tag-filters Key=Environment \
    --region "$REGION" --output json                > "$D/quet.json" 2>"$D/quet.err"
fi

########################################
# PHAN TICH
########################################
python3 - "$D" <<'PY'
import glob, json, os, sys

D = sys.argv[1]
XANH, DO, VANG, HET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"
loi, canh = [], []

HOP_LE = {"dev", "staging", "prod", "sandbox"}


def doc(ten):
    """Tra ve (du_lieu, thong_bao_loi).

    PHAI tra ve ca hai. "File rong" va "AWS tra ve loi" va "JSON hong"
    la ba viec khac nhau, va gop chung thanh None la dung cai khuyet
    diem ma ca script nay duoc viet ra de chan.
    """
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


####################################
# 1. TAG_POLICY DA BAT TREN ROOT CHUA
#
# Chua bat thi CreatePolicy tra ve PolicyTypeNotEnabledException. Neu
# policy da ton tai thi phep kiem nay di nhien dat - nhung no van o day
# vi no tra loi duoc cho truong hop NGUOC: policy khong ton tai, va can
# biet vi sao.
####################################
print()
d, e = doc("roots.json")
root_id = ""
if d is None:
    loi.append(f"khong doc duoc list-roots. Day KHONG phai 'khong co root'.\n       {e}")
else:
    roots = d.get("Roots") or []
    if not roots:
        loi.append("list-roots tra ve 0 root - doc duoc nhung rong.")
    else:
        root_id = roots[0]["Id"]
        bat = [p["Type"] for p in roots[0].get("PolicyTypes", []) if p.get("Status") == "ENABLED"]
        if "TAG_POLICY" in bat:
            print(f"  {XANH}v{HET} TAG_POLICY da bat tren root {root_id}  (dang bat: {', '.join(bat)})")
        else:
            loi.append(
                f"TAG_POLICY CHUA bat tren root {root_id} (dang bat: {', '.join(bat) or 'khong gi'}).\n"
                f"       aws organizations enable-policy-type --root-id {root_id} --policy-type TAG_POLICY"
            )

####################################
# 2. CO POLICY NAO
####################################
d, e = doc("policies.json")
pols = []
if d is None:
    loi.append(f"khong doc duoc list-policies TAG_POLICY.\n       {e}")
else:
    pols = d.get("Policies") or []

if not pols and d is not None:
    loi.append(
        "KHONG co tag policy nao trong to chuc.\n"
        "       enable_tag_policy = true chua duoc apply, hoac stage sec-tagging dang tat.\n"
        "       Kiem: cd ../ops-pipeline && grep enable_tagging_stage terraform.tfvars"
    )

for p in pols:
    print(f"  {XANH}v{HET} tag policy {p['Name']}  ({p['Id']})")

####################################
# 3. NOI DUNG: KHOA NAO CHAN, KHOA NAO CHI BAO CAO
#
# Phep kiem quan trong nhat cua ca script. enforced_for RONG nghia la
# policy do KHONG CHAN GI - no chi ghi vao bao cao tuan thu. Doc "policy
# ton tai" thanh "tag da duoc ep buoc" la cach hieu sai pho bien nhat ve
# tag policy.
####################################
for p in pols:
    pid = p["Id"]
    print()
    noi, e = doc(f"noidung-{pid}.json")
    if noi is None:
        loi.append(f"khong doc duoc describe-policy {pid}.\n       {e}")
    else:
        tags = noi.get("tags") or {}
        if not tags:
            loi.append(f"{pid} co noi dung nhung KHONG khoa nao - policy rong.")
        chan = []
        for key, cfg in sorted(tags.items()):
            gt = (cfg.get("tag_value") or {}).get("@@assign")
            ep = (cfg.get("enforced_for") or {}).get("@@assign")
            mo = ", ".join(gt) if gt else "bat ky"
            if ep:
                chan.append(key)
                print(f"    {key:<12} gia tri: {mo}")
                print(f"    {'':<12} {DO}CHAN{HET} tren: {', '.join(ep)}")
            else:
                print(f"    {key:<12} gia tri: {mo}   -> {VANG}CHI BAO CAO{HET}")

        # Environment phai giu dung bon gia tri cua doc 11 muc 2.
        env = (tags.get("Environment", {}).get("tag_value") or {}).get("@@assign")
        if env is not None and set(env) != HOP_LE:
            loi.append(
                f"{pid}: Environment cho phep {sorted(env)}, khac bon gia tri cua "
                f"doc 11 muc 2 {sorted(HOP_LE)}. Them mot gia tri thu nam lam moi "
                "bao cao chi phi theo moi truong lech."
            )

        if tags and not chan:
            canh.append(
                f"{pid} dang o che do CHI BAO CAO.\n"
                "       Do la trang thai KHOI DAU dung (nhip 1), khong phai loi. Nhung\n"
                "       dung dung lai o day va tuong tag da duoc ep buoc: mot lenh gan\n"
                '       Environment = "shared" ngay luc nay VAN THANH CONG.\n'
                "       Nhip 2: them enforced_for cho tung khoa mot - xem\n"
                "       terraform.tfvars.example muc 8."
            )

    ####################################
    # GAN VAO DAU
    #
    # Mot policy ton tai ma khong gan vao target nao la mot policy KHONG
    # CO TAC DUNG - va no khong co trieu chung nao: van hien trong
    # console, van co noi dung dung.
    ####################################
    tg, e = doc(f"target-{pid}.json")
    if tg is None:
        loi.append(f"khong doc duoc list-targets-for-policy {pid}.\n       {e}")
    else:
        ts = tg.get("Targets") or []
        if not ts:
            loi.append(
                f"{pid} KHONG gan vao target nao - policy khong co tac dung.\n"
                "       No van hien trong console va van co noi dung dung, nen cho nay\n"
                "       khong co trieu chung nao."
            )
        for t in ts:
            print(f"    gan vao    : {t['Type']:<12} {t['Name']} ({t['TargetId']})")

####################################
# 4. BAO CAO TUAN THU - VA CAI BAY LON NHAT KHI DOC NO
#
# AWS can toi 48 GIO de quet lan dau sau khi bat tag policy. Truoc do
# bao cao RONG - va rong o day nghia la "CHUA DANH GIA", khong phai "moi
# thu tuan thu".
#
# Cung ho voi INSUFFICIENT_DATA cua Config: mot cho trong bi doc thanh
# mot cau tra loi. Day la dang loi lap lai nhieu nhat trong du an nay.
####################################
print()
d, e = doc("tuanthu.json")
if d is None:
    canh.append(
        "KHONG doc duoc bao cao tuan thu (get-compliance-summary).\n"
        f"       {e}\n"
        "       Day KHONG phai 'khong co resource nao sai'."
    )
else:
    s = d.get("SummaryList") or []
    if not s:
        print("  Bao cao tuan thu: CHUA CO DU LIEU.")
        print("    AWS can toi 48 gio de quet lan dau sau khi bat tag policy.")
        print('    RONG o day nghia la CHUA DANH GIA, khong phai "moi thu tuan thu".')
    else:
        tong = 0
        for x in s:
            n = x.get("NonCompliantResources", 0)
            tong += n
            ten = x.get("TargetId") or "?"
            loai = x.get("ResourceType") or "moi loai"
            print(f"  {ten:<14} {loai:<20} khong tuan thu: {n}")
        print(f"\n  Tong khong tuan thu: {tong}")

####################################
# 5. QUET Environment SAI GIA TRI - PHAM VI HEP, VA NOI RO LA HEP
#
# resourcegroupstaggingapi KHONG lien account va chi hoi MOT region. Nen
# ket qua 0 o day tra loi dung mot cau: "trong account nay, o region
# nay, khong resource nao mang gia tri la". No KHONG tra loi cho ca to
# chuc.
#
# Ghi ra vi da tung doc sai chinh cho nay: quet management/ap-southeast-1
# ra 0 SAU KHI da sua ca hai resource sai, roi suyt ket luan la ca to
# chuc sach.
####################################
print()
d, e = doc("quet.json")
if d is None:
    canh.append(f"KHONG quet duoc gia tri Environment (get-resources).\n       {e}")
else:
    r = d.get("ResourceTagMappingList") or []
    sai = [
        (t["Value"], x["ResourceARN"])
        for x in r for t in x.get("Tags", [])
        if t["Key"] == "Environment" and t["Value"] not in HOP_LE
    ]
    print(f"  Quet Environment: {len(r)} resource co tag nay, {len(sai)} mang gia tri ngoai {sorted(HOP_LE)}")
    for v, a in sai:
        print(f"    {v!r}  {a}")
    print("    (CHI account nay, CHI region nay - khong phai ca to chuc)")
    if sai:
        loi.append(
            f"{len(sai)} resource mang Environment ngoai bon gia tri cua doc 11 muc 2."
        )

####################################
print()
for c in canh:
    print(f"  {VANG}CANH BAO{HET} {c}")
for l in loi:
    print(f"  {DO}LOI{HET}  {l}")

print()
if loi:
    print(f"  {DO}{len(loi)} loi{HET}, {len(canh)} canh bao.")
    sys.exit(1)
if canh:
    print(f"  {VANG}{len(canh)} canh bao{HET}, 0 loi.")
    sys.exit(0)
print(f"  {XANH}Tag policy dang chan that.{HET} 0 canh bao.")
PY
