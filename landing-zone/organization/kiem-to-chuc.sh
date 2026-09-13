#!/usr/bin/env bash
#
# Kiem cay OU, SCP va tag policy DANG THAT o AWS - khong doc Terraform state.
# Va doc lai LOG cua lan chay pipeline vua roi de tim canh bao.
#
#   ./kiem-to-chuc.sh
#
# Khong tham so. Bien moi truong:
#
#   PIPELINE    ten pipeline de doc log (rong = bo qua phan log, va NOI RO)
#   LOG_GROUP   mac dinh /aws/codebuild/$PIPELINE
#   TU_THU_MUC  doc JSON co san, khong goi AWS - de test offline
#
# ======================================================================
# HAI CAU HOI, VA KHONG LOP NAO KHAC TRA LOI CHUNG
#
# 1. APPLY DA CO TAC DUNG CHUA
#
# `terraform output` doc STATE. State noi rang Terraform DA GOI API va AWS
# tra ve 200 - no khong noi policy gan vao dau, hay no co CHAN gi khong.
#
#   loi 121  moi apply xanh trong ba thang deu la no-op, nen "pipeline
#            chay on" chua bao gio co nghia la "apply duoc"
#   loi 126  mot SCP go sai ten action van apply thanh cong, van nam
#            trong policy, va chan dung 0 thu
#
# 2. LAN CHAY DO CO CANH BAO GI KHONG
#
# Mot check block cua Terraform that bai, mot dong "Objects have changed
# outside of Terraform", mot canh bao cua -target - tat ca di qua ma stage
# van XANH. Va khong ai mo log cua mot build mau xanh.
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
set -uo pipefail

XANH=$'\033[32m'; DO=$'\033[31m'; VANG=$'\033[33m'; HET=$'\033[0m'

########################################
# KHONG CO CHE DO, KHONG CO THAM SO LOC
#
# Truoc day script nay co `ou|scp|tag` va `--tuc-thi|--tre`. Chung sinh ra
# de phuc vu mot thiet ke da bo: mot action verify cho TUNG stage. Voi mot
# buoc verify duy nhat o cuoi pipeline thi khong con gi de loc - va mot co
# khong ai dat la mot co khong ai thu.
#
# Bien moi truong thi con, va chung la DAU VAO chu khong phai che do:
#
#   PIPELINE   ten pipeline de doc lai log cua lan chay nay. Rong = bo qua
#              phan log, VA NOI RO la bo qua.
#   LOG_GROUP  log group cua cac build. Mac dinh /aws/codebuild/$PIPELINE.
#   TU_THU_MUC doc JSON co san, khong goi AWS. Danh cho test offline.
########################################
if [[ $# -gt 0 ]]; then
  echo "Script nay khong nhan tham so (nhan duoc: $*)."
  echo "Bien moi truong: PIPELINE, LOG_GROUP, TU_THU_MUC."
  exit 2
fi

PIPELINE="${PIPELINE:-}"
LOG_GROUP="${LOG_GROUP:-${PIPELINE:+/aws/codebuild/$PIPELINE}}"

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
  if [[ -n "$ROOT" ]]; then
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
  aws resourcegroupstaggingapi get-compliance-summary --group-by TARGET_ID \
    --region "${TAG_REGION:-us-east-1}" --output json > "$D/tuanthu.json" 2>"$D/tuanthu.err"

  aws resourcegroupstaggingapi get-resources --tag-filters Key=Environment \
    --region "$REGION" --output json > "$D/quet.json" 2>"$D/quet.err"

  ####################################
  # LOG CUA CHINH LAN CHAY NAY
  #
  # Khoang trong ma khong lop nao doc: CANH BAO. Mot check block cua
  # Terraform that bai, mot dong "Objects have changed outside of
  # Terraform", mot canh bao cua -target - tat ca di qua ma stage van
  # XANH. Khong ai mo log cua mot build mau xanh.
  #
  # Quet theo THOI GIAN chu khong theo execution id: mot lenh
  # FilterLogEvents tren log group, tu 40 phut truoc. Khong can goi
  # codepipeline, khong can ghep action voi build.
  #
  # 40 phut: dai hon mot luot pipeline (do duoc ~15 phut cho ba stage) va
  # ngan hon khoang giua hai luot. Qua ngan thi bo sot stage dau; qua dai
  # thi keo canh bao cua luot TRUOC vao luot nay.
  ####################################
  if [[ -n "$LOG_GROUP" ]]; then
    TU=$(( ($(date +%s) - 40 * 60) * 1000 ))
    aws logs filter-log-events \
      --log-group-name "$LOG_GROUP" \
      --start-time "$TU" \
      --region "$REGION" --output json > "$D/log.json" 2>"$D/log.err"
  fi
fi

########################################
# PHAN TICH
########################################
python3 - "$D" "${CODEBUILD_LOG_PATH:-}" <<'PY'
import glob, json, os, sys

D = sys.argv[1]
# Stream log cua CHINH build nay. Bo ra khoi phep quet - neu khong thi
# script se thay "CANH BAO" do CHINH NO in ra va bao co van de, moi lan.
STREAM_TOI = sys.argv[2] if len(sys.argv) > 2 else ""
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
if True:
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
if True:
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
# 6. LOG CUA LAN CHAY PIPELINE VUA ROI
#
# Khoang trong ma khong lop nao doc: CANH BAO. Mot check block cua
# Terraform that bai, mot dong "Objects have changed outside of Terraform",
# mot canh bao cua -target - tat ca di qua ma stage van XANH, va khong ai
# mo log cua mot build mau xanh.
#
# BA DIEU DE SAI KHI DOC LOG, va ca ba da duoc xu ly:
#
#   1. Stream cua CHINH build nay cung nam trong log group. Khong tru no
#      ra thi script thay "CANH BAO" do chinh no in va bao co van de, moi
#      lan chay.
#   2. Log RONG khong phai "khong co canh bao" - co the la sai log group,
#      sai region, hay thieu quyen. Ba truong hop khac nhau.
#   3. Mot dong khop KHONG phai mot su co. `Warning: Resource targeting is
#      in effect` xuat hien o MOI lan chay vi -target la thiet ke cua
#      pipeline nay. Nen no nam trong danh sach BIET ROI.
####################################
tieu_de("Log cua lan chay vua roi")

# Mau khop -> co phai canh bao MOI hay khong.
#
# "Resource targeting is in effect" va "Applied changes may be incomplete"
# la he qua truc tiep cua -target, tuc thiet ke cua pipeline. Bao chung
# moi lan la cach nhanh nhat lam nguoi ta thoi doc phan nay.
BIET_ROI = (
    "Resource targeting is in effect",
    "Applied changes may be incomplete",
    "The -target option is not for routine use",
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

d, e = doc("log.json")
if d is None:
    if not e or "khong co file" in e:
        # Khong goi = khong co PIPELINE/LOG_GROUP. Noi ro la BO QUA, khong
        # de no im lang thanh mot phan "dat".
        canh.append(
            "KHONG doc log: thieu PIPELINE hoac LOG_GROUP.\n"
            "       Phan nay bi BO QUA - khong phai 'lan chay khong co canh bao'."
        )
    else:
        canh.append(
            "KHONG doc duoc log cua lan chay.\n"
            f"       {e}\n"
            "       Day KHONG phai 'khong co canh bao nao'. Thieu quyen thi them\n"
            "       logs:FilterLogEvents cho role CodeBuild."
        )
else:
    su_kien = [
        x for x in (d.get("events") or [])
        if x.get("logStreamName") != STREAM_TOI
    ]
    thay = {}
    for x in su_kien:
        t = (x.get("message") or "").strip()
        if any(b in t for b in BIET_ROI):
            continue
        for mau in DANG_TIM:
            if mau in t:
                thay.setdefault(mau, []).append(t[:160])
                break

    print(f"    {len(su_kien)} dong log (da tru stream cua chinh buoc nay)")
    if not su_kien:
        canh.append(
            "log group doc duoc nhung RONG trong 40 phut qua.\n"
            "       Doc duoc va rong la mot cau tra loi hop le - nhung o day no\n"
            "       kho tin: buoc verify nay chay SAU cac stage apply, nen log cua\n"
            "       chung phai con. Kiem lai ten log group va region."
        )
    elif not thay:
        print("    Khong co canh bao nao ngoai nhung dong biet roi cua -target.")
    else:
        for mau, ds in sorted(thay.items(), key=lambda kv: -len(kv[1])):
            print(f"    {VANG}{mau}{HET}  {len(ds)} dong")
            for t in ds[:3]:
                print(f"      {t}")
            if len(ds) > 3:
                print(f"      ... con {len(ds) - 3} dong nua")
        nang = [m for m in thay if m in ("Error:", "error occurred", "AccessDenied")]
        if nang:
            loi.append(
                f"log cua lan chay co dong bao LOI ({', '.join(nang)}) du stage van xanh. "
                "Doc log truoc khi tin ket qua."
            )
        else:
            canh.append(
                f"log cua lan chay co {sum(len(v) for v in thay.values())} dong canh bao "
                f"({', '.join(sorted(thay))}). Stage xanh khong co nghia la khong co gi."
            )

####################################
print()
for c in canh:
    print(f"  {VANG}CANH BAO{HET} {c}")
for l in loi:
    print(f"  {DO}LOI{HET}  {l}")

print()
print("  Da kiem: cay OU, SCP, tag policy, log lan chay.")
if loi:
    print(f"  {DO}{len(loi)} loi{HET}, {len(canh)} canh bao.")
    sys.exit(1)
if canh:
    print(f"  {VANG}{len(canh)} canh bao{HET}, 0 loi.")
    sys.exit(0)
print(f"  {XANH}Khop het.{HET} 0 canh bao.")
PY
