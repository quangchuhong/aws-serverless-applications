#!/usr/bin/env bash
#
# Kiem cay OU, SCP va tag policy DANG THAT o AWS - khong doc Terraform state.
#
#   ./kiem-to-chuc.sh            ca ba
#   ./kiem-to-chuc.sh ou         chi cay OU
#   ./kiem-to-chuc.sh scp        chi SCP
#   ./kiem-to-chuc.sh tag        chi tag policy
#
#   --tuc-thi   BO nhung phep do TRE (bao cao tuan thu tag policy). Day la
#               che do pipeline dung o stage Verify.
#   --tre       CHI nhung phep do tre. Danh cho job chay theo lich.
#
# Khong co co nao = ca hai nhom, danh cho nguoi chay tay.
#
# ======================================================================
# VI SAO CAN, KHI `terraform output` DA IN RA DAY DU
#
# output doc STATE. State noi rang Terraform DA GOI API va AWS tra ve 200
# - no khong noi policy dang gan vao dau, noi dung con dung khong, hay no
# co CHAN gi khong.
#
# Hai lan da mat de biet dieu do:
#
#   loi 121  moi apply xanh trong ba thang deu la no-op, nen "pipeline
#            chay on" chua bao gio co nghia la "apply duoc"
#   loi 126  mot SCP go sai ten action van apply thanh cong, van nam
#            trong policy, va chan dung 0 thu
#
# ======================================================================
# TACH --tuc-thi VOI --tre THEO DO TRE CUA DU LIEU, KHONG THEO MUC QUAN TRONG
#
# Stage Verify chay NGAY sau apply. Nhung phep do co du lieu ngay - OU ton
# tai, SCP gan vao target nao, tag policy co enforced_for gi - tra loi
# duoc o day.
#
# Bao cao tuan thu tag policy thi KHONG: AWS can toi 48 gio de quet lan
# dau. Dat no vao stage Verify thi no vinh vien in "chua co du lieu", va
# mot dong luon giong nhau la mot dong khong ai doc nua. Nen no thuoc
# --tre, chay theo lich cung job drift.
#
# ======================================================================
# BA TANG, VA SCRIPT NAY CHI DO TANG THU NHAT CUA TAG
#
#   tag policy           ep DUNG CACH VIET va GIA TRI hop le  <- o day
#   SCP                  chan TAO resource khi thieu tag
#   Config required-tags PHAT HIEN resource da co ma thieu tag
#
# Nhac lai dieu hay bi hieu nham nhat: tag policy KHONG lam tag tro thanh
# bat buoc. No chi quan ly GIA TRI cua mot tag KHI tag do duoc gan. Mot
# EC2 instance khong co tag nao ca thi no khong noi gi het, ke ca da bat
# enforced_for.
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
#   TU_THU_MUC=/duong/dan ./kiem-to-chuc.sh   doc file co san, khong goi AWS
#
set -uo pipefail

XANH=$'\033[32m'; DO=$'\033[31m'; VANG=$'\033[33m'; HET=$'\033[0m'

########################################
# THAM SO
#
# MAC DINH LA "TAT CA", khong phai "khong gi". Goi script khong tham so
# roi nhan mot dong "xong" ma no chua kiem gi la dang hong te nhat cua ca
# file nay - nen khong co che do rong.
########################################
PHAN="ou scp tag"
NHOM="tuc-thi tre"

for A in "$@"; do
  case "$A" in
    ou|scp|tag) PHAN="$A" ;;
    --tuc-thi)  NHOM="tuc-thi" ;;
    --tre)      NHOM="tre" ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Tham so khong hieu: $A"
      echo "Dung: $0 [ou|scp|tag] [--tuc-thi|--tre]"
      exit 2
      ;;
  esac
done

co() { [[ " $PHAN " == *" $1 "* ]]; }
nhom() { [[ " $NHOM " == *" $1 "* ]]; }

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
  echo "Vung               : $REGION  (bao cao tuan thu: ${TAG_REGION:-us-east-1})"

  ########################################
  # GOI. Loi cua AWS duoc GHI VAO FILE chu khong bi vut di: khoi python
  # phan biet "doc duoc va rong" voi "khong doc duoc", va no chi lam
  # duoc dieu do neu con thay thong bao loi.
  ########################################
  aws organizations list-roots --output json > "$D/roots.json" 2>"$D/roots.err"

  ROOT=$(python3 - "$D/roots.json" <<'PY'
import json, sys
try:
    r = json.load(open(sys.argv[1]))["Roots"]
except Exception:
    sys.exit(0)
print(r[0]["Id"] if r else "")
PY
  )

  ####################################
  # CAY OU - LIET KE DE QUY
  #
  # list-organizational-units-for-parent chi tra ve MOT tang. Cay o day
  # co hai tang (Workloads/Production), nen phai duyet xuong - neu khong
  # thi "Workloads/Production khong ton tai" se la mot ket luan sai rut
  # ra tu mot phep hoi khong day du.
  ####################################
  if co ou && [[ -n "$ROOT" ]]; then
    aws organizations list-organizational-units-for-parent --parent-id "$ROOT" \
      --output json > "$D/ou-$ROOT.json" 2>"$D/ou-$ROOT.err"

    for OU in $(python3 - "$D/ou-$ROOT.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for o in d.get("OrganizationalUnits", []):
    print(o["Id"])
PY
    ); do
      aws organizations list-organizational-units-for-parent --parent-id "$OU" \
        --output json > "$D/ou-$OU.json" 2>"$D/ou-$OU.err"
    done
  fi

  ####################################
  # SCP VA TAG POLICY - CUNG MOT HINH DANG
  #
  # Hai loai policy, cung ba cau hoi: co khong, noi dung gi, gan vao dau.
  # Nen chung dung cung mot vong lap va cung mot ten file.
  ####################################
  for LOAI in SERVICE_CONTROL_POLICY TAG_POLICY; do
    case "$LOAI" in
      SERVICE_CONTROL_POLICY) co scp || continue ;;
      TAG_POLICY)             co tag || continue ;;
    esac

    aws organizations list-policies --filter "$LOAI" --output json \
      > "$D/policies-$LOAI.json" 2>"$D/policies-$LOAI.err"

    for PID in $(python3 - "$D/policies-$LOAI.json" <<'PY'
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
        --query 'Policy.Content' --output text > "$D/noidung-$PID.json" 2>"$D/noidung-$PID.err"
      aws organizations list-targets-for-policy --policy-id "$PID" --output json \
        > "$D/target-$PID.json" 2>"$D/target-$PID.err"
    done
  done

  ####################################
  # BAO CAO TUAN THU CHI CHAY O us-east-1
  #
  # Khong phai mot lua chon, la gioi han cua AWS: GetComplianceSummary la
  # API toan TO CHUC va chi duoc phuc vu tu us-east-1. Goi o region khac
  # tra ve
  #
  #   InvalidParameterException: Requested API is not available in this
  #   region.
  #
  # Do duoc bang mot lan chay that o ap-southeast-1. Va day la ly do khoi
  # python KHONG duoc phep coi loi la "khong co du lieu": neu no lam vay,
  # cai loi nay se thanh mot bao cao tuan thu SACH vinh vien cho mot API
  # chua bao gio duoc goi thanh cong.
  #
  # TAG_REGION de ghi de neu mot ngay AWS mo rong sang region khac.
  ####################################
  if co tag && nhom tre; then
    aws resourcegroupstaggingapi get-compliance-summary --group-by TARGET_ID \
      --region "${TAG_REGION:-us-east-1}" --output json > "$D/tuanthu.json" 2>"$D/tuanthu.err"

    aws resourcegroupstaggingapi get-resources --tag-filters Key=Environment \
      --region "$REGION" --output json > "$D/quet.json" 2>"$D/quet.err"
  fi
fi

########################################
# PHAN TICH
########################################
python3 - "$D" "$PHAN" "$NHOM" <<'PY'
import glob, json, os, sys

D, PHAN, NHOM = sys.argv[1], sys.argv[2].split(), sys.argv[3].split()
XANH, DO, VANG, HET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"
loi, canh = [], []

# Bon gia tri cua doc 11 muc 2. Khong doc tu tfvars: script nay hoi AWS,
# va neu no lay chuan tu cung mot cho ma Terraform lay thi hai ben lech
# nhau se khong ai biet. Lech thi phep kiem duoi keu.
HOP_LE = {"dev", "staging", "prod", "sandbox"}


def doc(ten):
    """Tra ve (du_lieu, thong_bao_loi).

    PHAI tra ve ca hai. "File rong", "AWS tra ve loi" va "JSON hong" la
    ba viec khac nhau, va gop chung thanh None la dung cai khuyet diem
    ma ca script nay duoc viet ra de chan.
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


def tieu_de(t):
    print()
    print(f"── {t}")


####################################
# ROOT - MOI PHAN DEU CAN
####################################
d, e = doc("roots.json")
root_id = ""
root_bat = []
if d is None:
    loi.append(f"khong doc duoc list-roots. Day KHONG phai 'khong co root'.\n       {e}")
else:
    roots = d.get("Roots") or []
    if not roots:
        loi.append("list-roots tra ve 0 root - doc duoc nhung rong.")
    else:
        root_id = roots[0]["Id"]
        root_bat = [p["Type"] for p in roots[0].get("PolicyTypes", []) if p.get("Status") == "ENABLED"]

####################################
# 1. CAY OU
#
# Ba cau hoi, va chung khac nhau:
#
#   OU nao ton tai        cay dung hinh chua
#   account nao o ROOT    account chua vao OU nao thi KHONG SCP nao gan
#                         vao OU cham toi no - no chi chiu SCP gan o root
#   OU nao rong           khong phai loi, nhung mot OU rong ma duoc mot
#                         permission set tro vao la 0 assignment
#
# Cau thu hai la cau khong ai hoi: mot account nam o root van "trong to
# chuc", van hien trong console, va van thieu moi guardrail cua OU.
####################################
if "ou" in PHAN and "tuc-thi" in NHOM:
    tieu_de("Cay OU")
    if not root_id:
        loi.append("khong biet root id nen KHONG kiem duoc cay OU.")
    else:
        cay = {}
        thieu = []
        for f in sorted(glob.glob(os.path.join(D, "ou-*.json"))):
            pid = os.path.basename(f)[3:-5]
            dd, ee = doc(os.path.basename(f))
            if dd is None:
                thieu.append(f"{pid}: {ee}")
                continue
            cay[pid] = dd.get("OrganizationalUnits") or []

        if thieu:
            loi.append(
                "khong doc duoc mot so tang cua cay OU - ket qua duoi day KHONG day du:\n       "
                + "\n       ".join(thieu)
            )

        if not cay:
            loi.append("khong doc duoc tang nao cua cay OU.")
        else:
            tong = 0

            def ve(pid, sau=""):
                global tong
                for o in sorted(cay.get(pid, []), key=lambda x: x["Name"]):
                    tong += 1
                    con = cay.get(o["Id"])
                    dau = "  " if con is None else ("+ " if con else "  ")
                    print(f"    {sau}{dau}{o['Name']:<20} {o['Id']}")
                    ve(o["Id"], sau + "    ")

            ve(root_id)
            print(f"    {tong} OU")
            if tong == 0:
                loi.append(
                    "0 OU duoi root. Doc duoc va rong - nen day KHONG phai loi doc,\n"
                    "       la cay OU chua duoc tao hoac stage sec-ou dang tat."
                )

####################################
# 2. SCP VA 3. TAG POLICY - CUNG BA CAU HOI
#
#   co policy nao        list-policies
#   noi dung gi          describe-policy
#   gan vao dau          list-targets-for-policy
#
# Cau thu ba la cau de bo qua nhat, va no la cau quan trong nhat: mot
# policy KHONG gan vao target nao khong co tac dung gi, ma no van hien
# trong console voi noi dung dung.
####################################
for loai, ten_phan, nhan in (
    ("SERVICE_CONTROL_POLICY", "scp", "SCP"),
    ("TAG_POLICY", "tag", "Tag policy"),
):
    if ten_phan not in PHAN or "tuc-thi" not in NHOM:
        continue

    tieu_de(nhan)

    # Loai policy phai duoc BAT tren root, neu khong thi CreatePolicy tra
    # ve PolicyTypeNotEnabledException. Neu policy da ton tai thi phep
    # kiem nay di nhien dat - nhung no van o day vi no tra loi duoc cho
    # truong hop NGUOC: policy khong ton tai, va can biet vi sao.
    if root_bat and loai not in root_bat:
        loi.append(
            f"{loai} CHUA bat tren root {root_id} (dang bat: {', '.join(root_bat) or 'khong gi'}).\n"
            f"       aws organizations enable-policy-type --root-id {root_id} --policy-type {loai}"
        )
    elif root_bat:
        print(f"    {XANH}v{HET} {loai} da bat tren root {root_id}")

    d, e = doc(f"policies-{loai}.json")
    pols = []
    if d is None:
        loi.append(f"khong doc duoc list-policies {loai}.\n       {e}")
    else:
        pols = [p for p in (d.get("Policies") or []) if not p.get("AwsManaged")]
        if not pols:
            loi.append(
                f"KHONG co {nhan} nao do minh quan ly trong to chuc.\n"
                "       Doc duoc va rong - nen day KHONG phai loi doc. Stage tuong ung\n"
                "       dang tat, hoac layer chua duoc apply."
            )

    for p in pols:
        pid = p["Id"]
        print(f"    {XANH}v{HET} {p['Name']}  ({pid})")

        noi, e = doc(f"noidung-{pid}.json")
        if noi is None:
            loi.append(f"khong doc duoc describe-policy {pid}.\n       {e}")
        elif loai == "SERVICE_CONTROL_POLICY":
            st = noi.get("Statement") or []
            if not st:
                loi.append(f"{pid} khong co Statement nao - policy rong.")
            n = len(json.dumps(noi, separators=(",", ":")))
            print(f"      {len(st)} statement, {n} ky tu / 5120")
            if n > 5120:
                loi.append(f"{pid} dai {n} ky tu, vuot han muc 5120 cua AWS.")
            # Deny KHONG co Action lan NotAction thi khong chan gi - AWS
            # nhan policy do, va no im lang.
            for x in st:
                if x.get("Effect") == "Deny" and not x.get("Action") and not x.get("NotAction"):
                    loi.append(
                        f"{pid}/{x.get('Sid','(khong sid)')}: Deny khong co Action lan "
                        "NotAction - khong chan gi, va AWS van nhan."
                    )
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
                    print(f"      {key:<12} gia tri: {mo}")
                    print(f"      {'':<12} {DO}CHAN{HET} tren: {', '.join(ep)}")
                else:
                    print(f"      {key:<12} gia tri: {mo}   -> {VANG}CHI BAO CAO{HET}")

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
                print(f"      gan vao: {t['Type']:<12} {t['Name']} ({t['TargetId']})")

####################################
# 4. BAO CAO TUAN THU - PHEP DO TRE
#
# AWS can toi 48 GIO de quet lan dau sau khi bat tag policy. Truoc do bao
# cao RONG - va rong o day nghia la "CHUA DANH GIA", khong phai "moi thu
# tuan thu".
#
# Cung ho voi INSUFFICIENT_DATA cua Config: mot cho trong bi doc thanh
# mot cau tra loi. Day la dang loi lap lai nhieu nhat trong du an nay.
####################################
if "tag" in PHAN and "tre" in NHOM:
    tieu_de("Bao cao tuan thu tag (phep do TRE)")
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
            print("    CHUA CO DU LIEU.")
            print("      AWS can toi 48 gio de quet lan dau sau khi bat tag policy.")
            print('      RONG o day nghia la CHUA DANH GIA, khong phai "moi thu tuan thu".')
        else:
            tong = 0
            for x in s:
                n = x.get("NonCompliantResources", 0)
                tong += n
                print(f"    {x.get('TargetId') or '?':<14} {x.get('ResourceType') or 'moi loai':<20} khong tuan thu: {n}")
            print(f"    Tong khong tuan thu: {tong}")

    ####################################
    # 5. QUET Environment SAI GIA TRI - PHAM VI HEP, VA NOI RO LA HEP
    #
    # resourcegroupstaggingapi KHONG lien account va chi hoi MOT region.
    # Nen ket qua 0 o day tra loi dung mot cau: "trong account nay, o
    # region nay, khong resource nao mang gia tri la". No KHONG tra loi
    # cho ca to chuc.
    #
    # Ghi ra vi da tung doc sai chinh cho nay: quet
    # management/ap-southeast-1 ra 0 SAU KHI da sua ca hai resource sai,
    # roi suyt ket luan la ca to chuc sach.
    ####################################
    tieu_de("Quet gia tri Environment (phep do TRE, pham vi HEP)")
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
        print(f"    {len(r)} resource co tag Environment, {len(sai)} mang gia tri ngoai {sorted(HOP_LE)}")
        for v, a in sai:
            print(f"      {v!r}  {a}")
        print("      (CHI account nay, CHI region nay - khong phai ca to chuc)")
        if sai:
            loi.append(f"{len(sai)} resource mang Environment ngoai bon gia tri cua doc 11 muc 2.")

####################################
# KHONG PHAN NAO CHAY LA MOT LOI
#
# Tham so loc co the loai het moi phan - vi du `tag --tuc-thi` khi chi co
# phep do tre. Mot lan chay khong kiem gi ma bao "xong" la dang hong te
# nhat cua ca file nay.
####################################
chay = [
    p for p in PHAN
    if ("tuc-thi" in NHOM) or (p == "tag" and "tre" in NHOM)
]
if not chay:
    print()
    print(f"  {DO}KHONG phan nao duoc chay{HET} voi phan={PHAN} nhom={NHOM}.")
    print("  Mot lan chay khong kiem gi thi khong duoc bao la thanh cong.")
    sys.exit(1)

####################################
print()
for c in canh:
    print(f"  {VANG}CANH BAO{HET} {c}")
for l in loi:
    print(f"  {DO}LOI{HET}  {l}")

print()
print(f"  Da kiem: {', '.join(chay)}   nhom: {', '.join(NHOM)}")
if loi:
    print(f"  {DO}{len(loi)} loi{HET}, {len(canh)} canh bao.")
    sys.exit(1)
if canh:
    print(f"  {VANG}{len(canh)} canh bao{HET}, 0 loi.")
    sys.exit(0)
print(f"  {XANH}Khop het.{HET} 0 canh bao.")
PY
