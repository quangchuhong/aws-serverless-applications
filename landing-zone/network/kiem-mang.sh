#!/usr/bin/env bash
#
# Kiem lop VAN HANH network (network/ops) dang that o AWS.
#
#   ./kiem-mang.sh <arn-role-assume> <chua-dung|da-dung>
#
# TU_THU_MUC=<dir> de doc JSON co san (test offline).
#
# PHEP KIEM LOG KHONG O DAY: no chung cho moi pipeline nen nam o
# ../ops-gate/kiem-log.sh, va buildspec-verify.yml goi no LUON sau lenh nay.
#
# ======================================================================
# VI SAO KHONG DUNG verify.sh CO SAN - VA DAY KHONG PHAI TRUNG LAP
#
# landing-zone/network/verify.sh (850 dong) da kiem network rat ky, ke ca
# cho mot goi tin that di het duong. Nhung no KHONG dung duoc o buoc Verify
# cua pipeline, vi hai ly do doc lap nhau:
#
#   1. No doc `terraform output`, tuc doc STATE. buildspec-verify.yml CO Y
#      khong cai Terraform va khong doc state - xem khoi chu thich dau
#      buildspec do. Mot phep verify doc state tra loi dung cau hoi ma
#      state da tra loi roi.
#   2. No kiem layer network GOC (hub, spoke, tgw, firewall policy). Con
#      pipeline nay apply network/ops - DNS record, endpoint, route, load
#      balancer, alarm, rule group. Hai tap khac nhau.
#
# Nen verify.sh van la phep kiem sau khi dung ha tang bang tay; cai nay la
# phep kiem sau moi lan pipeline apply.
#
# ======================================================================
# PHAT HIEN TEN THEO HAU TO, KHONG GO TIEN TO
#
# Ten resource cua layer nay la "${local.hub.project}-...", va local.hub =
# data.terraform_remote_state.hub.outputs.ops_handles - tuc tien to den tu
# STATE CUA LAYER CHA, thu ma script nay khong doc.
#
# Va KHONG duoc doan no. Trong ha tang nay co HAI quy uoc ten cung ton
# tai: cac pipeline dung "qh11-lz", con config-detective va billing-guard
# dung "quh11-lz" (co chu y). Doan sai mot chu la moi phep loc tra ve rong,
# va rong se duoc doc thanh "khong co gi" - dung lop loi ghi day trong repo
# nay.
#
# Nen: loc theo HAU TO ("-ops-east-west", "-partner-vpn-DUT"), giong cach
# kiem-trail.sh loc trail theo IsOrganizationTrail chu khong theo ten.
#
# ======================================================================
# CAI KHONG KIEM O DAY - NOI RO, KHONG DE MAU XANH TU NOI HO
#
# 1. SO LUAT trong rule group KHONG duoc so voi catalog. Mot muc trong
#    firewall-rules.yaml co the thanh MOT dong Suricata phu nhieu port
#    (xem chu thich o firewall.tf: "nhieu port trong mot rule, thay vi mot
#    rule moi port"). Nen hai con so lech nhau mot cach HOP LE, va so chung
#    se sinh ra bao dong gia moi lan. Script chi BAO so dong Suricata doc
#    duoc.
#
# 2. INGRESS RULE cua partner service khong kiem o day: tim security group
#    dung can id tu state cua layer cha. Do la viec cua verify.sh.
#
# 3. DNS record khong kiem: theo chinh chu thich cua ops-pipeline-network,
#    "DNS record sai co trieu chung NGAY - co nguoi goi". Phep kiem nay
#    danh cho nhung thay doi KHONG co trieu chung.
#
set -uo pipefail

XANH=$'\033[32m'; DO=$'\033[31m'; VANG=$'\033[33m'; HET=$'\033[0m'

ARN_ROLE="${1:-}"
CHE_DO="${2:-}"

########################################
# HAI NGUYEN NHAN, HAI CACH CHUA - DUNG KHANG DINH MOT CAI
#
# Ban dau thong bao nay viet: "Gia tri do Terraform sinh ra, nen rong o
# day nghia la chuoi verify trong main.tf bi sua sai - KHONG phai nguoi
# dung go thieu."
#
# Cau do SAI ngay lan dau co nguoi chay tay: ho go `./kiem-mang.sh` khong
# tham so - dung nhu dong `#   ./kiem-mang.sh <arn> <che-do>` o dau file
# moi - va bi thong bao khang dinh rang loi nam o Terraform.
#
# Mot thong bao doan sai nguyen nhan thi TE HON mot thong bao ngan, vi no
# gui nguoi doc di dung huong khong co gi. Day la lan thu nam cung kieu
# trong du an nay.
########################################
if [[ "$CHE_DO" != "chua-dung" && "$CHE_DO" != "da-dung" ]]; then
  echo "${DO}LOI: thieu hoac sai tham so thu hai (che do).${HET}"
  echo "     Nhan duoc: '${CHE_DO}'"
  echo
  echo "     Cach dung:"
  echo "       ./kiem-mang.sh '<arn-role-assume>' chua-dung|da-dung"
  echo
  echo "     chua-dung : hai stage network dang TAT - KHONG duoc thay rule"
  echo "                 group hay alarm. Thay thi la ha tang khong ai quan."
  echo "     da-dung   : stage dang bat - rule group phai ton tai, phai duoc"
  echo "                 mot firewall policy doc toi, alarm phai co nguoi nhan."
  echo
  echo "     Chay TAY thi go thang hai tham so. Vi du hom nay:"
  echo "       ./kiem-mang.sh 'arn:aws:iam::<account-mang>:role/<role>' chua-dung"
  echo
  echo "     Chay TU PIPELINE thi Terraform sinh chuoi nay tu"
  echo "     enable_network_stage / enable_firewall_stage, nen rong o do la"
  echo "     dau hieu chuoi verify trong ops-pipeline-network/main.tf bi sua"
  echo "     hong - thuong la mat cap nhay don quanh ARN, lam bash gop khoang"
  echo "     trang va day che do len thanh tham so thu nhat."
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

########################################
# CHUA DUNG + KHONG CO ARN = KHONG DOC DUOC GI, VA PHAI NOI RA
#
# Day la trang thai hom nay: hai stage deu tat, ha tang network da xoa,
# network_deploy_role_arn con rong. Khong co credential vao account mang
# thi khong chung minh duoc ca su TON TAI lan su VANG MAT.
#
# Thoat 0 - vi khong co gi SAI - nhung in ro rang mot luot xanh o day
# khong chung minh dieu gi. Neu de im, no thanh "network da duoc kiem".
########################################
if [[ "$GOI_AWS" == "yes" && "$CHE_DO" == "chua-dung" && -z "$ARN_ROLE" ]]; then
  echo
  echo "${VANG}KHONG DOC GI - va day la ket qua dung, khong phai mot lan kiem xanh.${HET}"
  echo
  echo "  Hai stage network deu TAT (enable_network_stage, enable_firewall_stage)"
  echo "  va network_deploy_role_arn con RONG, nen khong co duong nao vao account"
  echo "  mang. Khong doc duoc thi khong chung minh duoc CA su ton tai LAN su"
  echo "  vang mat."
  echo
  echo "  Khi dung lai network:"
  echo "    1. dien network_deploy_role_arn trong tfvars cua ops-pipeline-network"
  echo "    2. bat enable_network_stage / enable_firewall_stage"
  echo "    3. apply caller do - chuoi verify tu doi sang 'da-dung'"
  echo
  echo "  Tu luc do phep kiem nay moi bat dau tra loi that."
  exit 0
fi

if [[ "$GOI_AWS" == "yes" ]]; then
  if [[ -n "$ARN_ROLE" ]]; then
    aws sts assume-role --role-arn "$ARN_ROLE" \
      --role-session-name verify-mang --region "$REGION" \
      --output json > "$D/assume.json" 2>"$D/assume.err"

    # Credential KHONG duoc in ra: `read` nuot stdout cua subshell.
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

  aws network-firewall list-rule-groups --scope ACCOUNT --type STATEFUL \
    --region "$REGION" --output json > "$D/rg-list.json" 2>"$D/rg-list.err"

  ARN_RG=$(python3 - "$D/rg-list.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for g in d.get("RuleGroups", []):
    if (g.get("Name") or "").endswith("-ops-east-west"):
        print(g.get("Arn", ""))
        break
PY
  )

  if [[ -n "$ARN_RG" ]]; then
    aws network-firewall describe-rule-group --rule-group-arn "$ARN_RG" \
      --type STATEFUL --region "$REGION" --output json \
      > "$D/rg.json" 2>"$D/rg.err"
  fi

  ####################################
  # RULE GROUP CO DUOC POLICY NAO DOC TOI KHONG
  #
  # Day la phep kiem quan trong nhat trong ca script. network/ops co
  # check "rule_group_is_referenced", nhung no so ARN voi mot BIEN tfvars
  # cua layer cha (ops_rule_group_arns) - tuc no kiem mot LOI KHAI, khong
  # kiem thuc te. Neu ai do sua firewall policy o console, bien tfvars van
  # khop va check van xanh.
  #
  # Rule group ton tai, du luat, va KHONG duoc policy nao doc toi thi moi
  # luong truoc day bi chan gio di qua - va khong co log nao noi rang mot
  # luat vua ngung co hieu luc. Cung ho voi loi 126: "policy chua
  # statement" va "guardrail chan duoc" la hai cau khac nhau.
  ####################################
  aws network-firewall list-firewall-policies --region "$REGION" \
    --output json > "$D/fp-list.json" 2>"$D/fp-list.err"

  : > "$D/fp.jsonl"
  for A in $(python3 - "$D/fp-list.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for p in d.get("FirewallPolicies", []):
    print(p.get("Arn", ""))
PY
  ); do
    aws network-firewall describe-firewall-policy --firewall-policy-arn "$A" \
      --region "$REGION" --output json >> "$D/fp.jsonl" 2>>"$D/fp.err" || true
  done

  aws cloudwatch describe-alarms --region "$REGION" --output json \
    > "$D/alarms.json" 2>"$D/alarms.err"
fi

########################################
# PHAN TICH
########################################
python3 - "$D" "$CHE_DO" "${ARN_ROLE:-}" <<'PY'
import json, os, sys

D, CHE_DO = sys.argv[1], sys.argv[2]
ARN_ROLE = sys.argv[3] if len(sys.argv) > 3 else ""
XANH, DO, VANG, HET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"
loi, canh = [], []

HAU_TO_ALARM = ("-partner-vpn-DUT", "-partner-vpn-mat-du-phong")


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


def doc_nhieu(ten):
    """File noi nhieu doi tuong JSON - `aws` in JSON NHIEU DONG nen khong
    tach duoc bang splitlines(); dung raw_decode va nhay theo vi tri."""
    p = os.path.join(D, ten)
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return []
    t = open(p).read()
    de, ra, i = json.JSONDecoder(), [], 0
    while i < len(t):
        while i < len(t) and t[i].isspace():
            i += 1
        if i >= len(t):
            break
        try:
            o, j = de.raw_decode(t, i)
        except Exception:
            break
        ra.append(o)
        i = j
    return ra


print()
print("── Dang doc bang danh tinh nao")
d, e = doc("who.json")
if d is None:
    print(f"  {VANG}khong doc duoc get-caller-identity{HET}: {e}")
else:
    print(f"    account  {d.get('Account')}")
    print(f"    arn      {d.get('Arn')}")
print(f"    assume   {ARN_ROLE or 'KHONG - doc truc tiep bang danh tinh CodeBuild'}")
print(f"    che do   {CHE_DO}")

####################################
# 1. RULE GROUP - CO TON TAI, VA CO DUOC DOC TOI
####################################
print()
print("── Nhom luat tuong lua (hau to -ops-east-west)")

d, e = doc("rg-list.json")
ten_rg, arn_rg = "", ""
if d is None:
    loi.append(f"khong doc duoc list-rule-groups.\n        {e}")
else:
    for g in d.get("RuleGroups") or []:
        if (g.get("Name") or "").endswith("-ops-east-west"):
            ten_rg, arn_rg = g.get("Name", ""), g.get("Arn", "")
            break

so_luat = None
if arn_rg:
    print(f"    {ten_rg}")
    dg, e1 = doc("rg.json")
    if dg is None:
        loi.append(f"thay rule group {ten_rg} nhung khong describe duoc.\n        {e1}")
    else:
        rs = ((dg.get("RuleGroup") or {}).get("RulesSource") or {}).get("RulesString", "")
        so_luat = len([x for x in rs.splitlines() if x.strip() and not x.strip().startswith("#")])
        cap = (dg.get("RuleGroupResponse") or {}).get("Capacity")
        print(f"        {so_luat} dong luat Suricata, capacity {cap}")
        print("        (so nay KHONG duoc so voi catalog - mot muc trong")
        print("         firewall-rules.yaml co the thanh mot dong phu nhieu port)")
else:
    print("    KHONG tim thay rule group nao co hau to -ops-east-west")

# Tap ARN ma cac firewall policy DANG doc toi.
duoc_doc = set()
ten_policy = {}
for o in doc_nhieu("fp.jsonl"):
    fp = o.get("FirewallPolicy") or {}
    ten = (o.get("FirewallPolicyResponse") or {}).get("FirewallPolicyName", "?")
    for r in (fp.get("StatefulRuleGroupReferences") or []):
        a = r.get("ResourceArn", "")
        if a:
            duoc_doc.add(a)
            ten_policy.setdefault(a, []).append(ten)

####################################
# 2. HAI ALARM - CO TON TAI, CO NGUOI NHAN, CO DUOC BAT
#
# Ba cach mot alarm khong bao duoc, va ca ba deu im lang:
#   khong ton tai        khong co gi do luong
#   AlarmActions rong    do duoc, va khong goi ai
#   ActionsEnabled false alarm doi mau trong console va khong goi ai
####################################
print()
print("── Alarm VPN doi tac")
d, e = doc("alarms.json")
thay_alarm = {}
if d is None:
    loi.append(f"khong doc duoc describe-alarms.\n        {e}")
else:
    for a in d.get("MetricAlarms") or []:
        ten = a.get("AlarmName", "")
        for h in HAU_TO_ALARM:
            if ten.endswith(h):
                thay_alarm[h] = a
                hd = a.get("AlarmActions") or []
                bat = a.get("ActionsEnabled")
                print(f"    {ten}")
                print(f"        {a.get('StateValue')}, {len(hd)} action, ActionsEnabled={bat}")
                if not hd:
                    loi.append(
                        f"alarm {ten} KHONG co AlarmActions - no do duoc va khong goi ai.\n"
                        "        Bien alarm_actions cua network/ops dang rong. Alarm doi mau\n"
                        "        trong console va khong co gi di ra ngoai."
                    )
                elif bat is False:
                    loi.append(
                        f"alarm {ten} co action nhung ActionsEnabled=false - da bi TAT.\n"
                        "        Alarm van doi mau trong console nen no trong nhu dang hoat dong."
                    )
                if a.get("StateValue") == "INSUFFICIENT_DATA":
                    canh.append(
                        f"alarm {ten} dang INSUFFICIENT_DATA - chua co so lieu de danh gia.\n"
                        "        Ngay sau apply thi binh thuong. Keo dai thi nghia la metric\n"
                        "        khong toi - luc do alarm ton tai ma khong bao gio bao."
                    )
                break

####################################
# KET LUAN THEO CHE DO
#
# Hai chieu, va CA HAI deu phai bao duoc: "khai la chua dung nhung ha tang
# con song" cung la mot cau tra loi sai nhu chieu nguoc lai.
####################################
print()
if CHE_DO == "chua-dung":
    print("── Ky vong: network CHUA duoc dung (hai stage deu tat)")
    con_song = []
    if arn_rg:
        con_song.append(f"rule group {ten_rg}")
    for h, a in thay_alarm.items():
        con_song.append(f"alarm {a.get('AlarmName')}")

    if con_song:
        canh.append(
            "Hai stage network dang TAT nhung ha tang cua layer nay VAN CON:\n"
            + "".join(f"          {x}\n" for x in con_song)
            + "        Nghia la co ha tang dang song ma KHONG pipeline nao quan: mot thay\n"
            "        doi o do se khong di qua gate.py, khong qua cong duyet, va drift\n"
            "        hang dem cung khong doc layer nay.\n"
            "        Hoac bat lai hai stage, hoac xoa het phan con lai."
        )
    else:
        print("    Khong thay rule group lan alarm nao - KHOP voi ky vong.")
        print("    Va day la mot phep do THAT: doc duoc bang danh tinh o tren, khong")
        print("    phai mot phep loc tra ve rong.")
else:
    print("── Ky vong: network DA duoc dung")
    if not ARN_ROLE:
        loi.append(
            "che do 'da-dung' nhung KHONG co ARN role de assume, nen dang doc bang\n"
            "        danh tinh CodeBuild o account management - noi khong co resource nao\n"
            "        cua layer nay. Moi phep loc se tra ve rong, va rong se doc thanh\n"
            "        'thieu het'. Dien network_deploy_role_arn."
        )
    if not arn_rg:
        loi.append(
            "KHONG co rule group nao co hau to -ops-east-west.\n"
            "        Stage tuong lua dang bat, nen day la thieu that - hoac rule group\n"
            "        chua duoc tao, hoac dang o region khac, hoac dang o ACCOUNT khac\n"
            "        (kiem dong 'account' o dau bao cao)."
        )
    elif arn_rg not in duoc_doc:
        loi.append(
            f"rule group {ten_rg} TON TAI nhung KHONG firewall policy nao doc toi no.\n"
            "        Moi luong truoc day bi chan gio DI QUA, va khong co log nao noi rang\n"
            "        mot luat vua ngung co hieu luc.\n"
            "        network/ops co check \"rule_group_is_referenced\", nhung no so ARN voi\n"
            "        BIEN ops_rule_group_arns cua layer cha - tuc kiem mot LOI KHAI, khong\n"
            "        kiem thuc te. Sua firewall policy o console thi bien van khop va check\n"
            "        van xanh.\n"
            f"        ARN can co trong policy: {arn_rg}"
        )
    else:
        print(f"    Duoc doc toi boi: {', '.join(ten_policy.get(arn_rg, []))}")

    for h in HAU_TO_ALARM:
        if h not in thay_alarm:
            loi.append(
                f"KHONG co alarm nao co hau to {h}.\n"
                "        Khong co gi do trang thai tunnel VPN, nen mot tunnel sap se khong\n"
                "        bao ai. Trieu chung duy nhat la ung dung cham hoac mat ket noi."
            )

####################################
# CAI KHONG KIEM - NOI RO
####################################
print()
print("  Script nay KHONG kiem ba thu, va do la lua chon:")
print("    1. SO LUAT so voi catalog - mot muc firewall-rules.yaml co the thanh")
print("       mot dong Suricata phu nhieu port, nen hai so lech nhau HOP LE.")
print("    2. INGRESS RULE cua partner service - tim security group can id tu")
print("       state layer cha. Do la viec cua ./verify.sh.")
print("    3. DNS record - theo chu thich cua ops-pipeline-network, DNS sai co")
print("       trieu chung NGAY. Lop nay danh cho thay doi KHONG co trieu chung.")

print()
for c in canh:
    print(f"  {VANG}CANH BAO{HET} {c}")
for l in loi:
    print(f"  {DO}LOI{HET}  {l}")

print()
print(f"  Da kiem: rule group, {len(thay_alarm)}/2 alarm  (che do {CHE_DO})")
if loi:
    print(f"  {DO}{len(loi)} loi{HET}, {len(canh)} canh bao.")
    sys.exit(1)
if canh:
    print(f"  {VANG}{len(canh)} canh bao{HET}, 0 loi.")
    sys.exit(0)
print(f"  {XANH}Khop voi ky vong '{CHE_DO}'.{HET} 0 canh bao.")
PY
