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
# KHONG CO ARN KHONG CO NGHIA LA KHONG DOC DUOC
#
# Ban dau cho nay co mot loi tat: "che do chua-dung + ARN rong" thi in mot
# khoi "KHONG DOC GI" roi thoat 0, khong goi AWS lan nao.
#
# Loi tat do SAI, va no lo ra ngay lan chay tay dau tien. Nguoi chay dang
# dang nhap SSO THANG VAO account mang:
#
#   arn:aws:sts::436908791055:assumed-role/AWSReservedSSO_lz-account-admin/quang
#
# Ho khong can assume - va OrganizationAccountAccessRole cua chinh account
# do khong tin ho, no tin account management. Nen ep truyen ARN la ep mot
# thu vua thua vua khong lam duoc.
#
# Dau hieu DUNG de biet co chung minh duoc gi hay khong la PHEP DOC CO
# THANH CONG HAY KHONG, chu khong phai co truyen ARN hay khong. Nen o day
# luon doc; phan phan tich moi quyet dinh.
########################################
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

  ####################################
  # MAT XICH THU BA: TOPIC CO AI DANG KY CHUA
  #
  # "alarm co 1 action" moi chung minh duoc hai mat xich: alarm -> topic.
  # Mat thu ba - topic -> nguoi nhan - van co the dut, va dut trong im
  # lang: SNS de subscription o PendingConfirmation cho toi khi co nguoi
  # bam link trong thu, va o trang thai do no khong nhan gi.
  #
  # Terraform khong tra loi duoc cau nay: no bao tao thanh cong va plan ra
  # "No changes" o CA HAI trang thai. Phai hoi AWS.
  #
  # Chi hoi nhung topic ma alarm CUA LAYER NAY dang tro toi.
  ####################################
  : > "$D/subs.jsonl"
  for T in $(python3 - "$D/alarms.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
ra = set()
for a in d.get("MetricAlarms", []):
    ten = a.get("AlarmName", "")
    if not (ten.endswith("-partner-vpn-DUT") or ten.endswith("-partner-vpn-mat-du-phong")):
        continue
    for x in (a.get("AlarmActions") or []) + (a.get("OKActions") or []):
        if x.startswith("arn:aws:sns:"):
            ra.add(x)
for x in sorted(ra):
    print(x)
PY
  ); do
    aws sns list-subscriptions-by-topic --topic-arn "$T" --region "$REGION" \
      --output json 2>>"$D/subs.err" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); d['__topic']='$T'; print(json.dumps(d))" \
      >> "$D/subs.jsonl" 2>>"$D/subs.err" || true
  done
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
# "danh tinh CodeBuild" la mot phong doan, khong phai mot phep doc.
# Script nay chay ca trong pipeline LAN bang tay, va lan chay tay dau tien
# la mot nguoi dang nhap SSO - dong cu bao ho rang ho la CodeBuild. Ten
# dung o ngay dong `arn` phia tren; dong nay chi noi CO assume hay khong.
print(f"    assume   {ARN_ROLE or 'KHONG - doc bang danh tinh dang co (xem arn o tren)'}")
print(f"    che do   {CHE_DO}")

####################################
# 1. RULE GROUP - CO TON TAI, VA CO DUOC DOC TOI
####################################
print()
print("── Nhom luat tuong lua (hau to -ops-east-west)")

####################################
# KHONG DOC DUOC != KHONG CO
#
# list-rule-groups that bai (AccessDenied, sai region, chua bat Network
# Firewall) thi KHONG ket luan duoc gi - ke ca chieu "vang mat". Day la
# lop loi ghi day trong repo nay, va no nguy hiem nhat o dung che do
# chua-dung: mot phep doc hong se doc thanh "khong thay gi - khop ky vong".
#
#   chua-dung  -> in ro la khong kiem duoc, thoat 0 (khong co gi SAI,
#                 nhung cung khong chung minh duoc gi)
#   da-dung    -> LOI: stage dang bat ma khong doc duoc la khong chap nhan
####################################
d, e = doc("rg-list.json")
ten_rg, arn_rg = "", ""
doc_duoc = d is not None
if d is None:
    print()
    print(f"  {VANG}KHONG DOC DUOC list-rule-groups.{HET}")
    print(f"        {e}")
    print()
    if CHE_DO == "chua-dung":
        print("  Nen khong ket luan duoc gi - KE CA chieu 'khong co gi'. Mot phep doc")
        print("  hong va mot he thong rong deu cho ra danh sach trong.")
        print()
        print("  Thoat 0 vi khong co gi SAI, nhung lan chay nay KHONG chung minh dieu gi.")
        sys.exit(0)
    loi.append(
        "che do 'da-dung' ma khong doc duoc list-rule-groups.\n"
        f"        {e}\n"
        "        Stage dang bat nen khong doc duoc la khong chap nhan duoc: no che"
        " mat\n        dung cai ma buoc verify sinh ra de nhin."
    )
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
mac_dinh_policy = {}
for o in doc_nhieu("fp.jsonl"):
    fp = o.get("FirewallPolicy") or {}
    ten = (o.get("FirewallPolicyResponse") or {}).get("FirewallPolicyName", "?")
    for r in (fp.get("StatefulRuleGroupReferences") or []):
        a = r.get("ResourceArn", "")
        if a:
            duoc_doc.add(a)
            ten_policy.setdefault(a, []).append(ten)
            # Hanh dong MAC DINH cua policy - xem khoi "CHE DO" ben duoi.
            mac_dinh_policy[ten] = fp.get("StatefulDefaultActions") or []

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
# 3. TOPIC CO AI DANG KY, VA DA XAC NHAN CHUA
#
# "alarm co 1 action" chi chung minh alarm -> topic. Mat xich thu ba -
# topic -> nguoi nhan - dut duoc ma moi lop van xanh: SNS de subscription
# o PendingConfirmation cho toi khi co nguoi bam link trong thu, va o
# trang thai do no khong nhan gi. Terraform bao tao thanh cong va plan ra
# "No changes" o CA HAI trang thai.
####################################
if thay_alarm:
    print()
    print("── Nguoi nhan cua topic bao dong")
    sub_theo_topic = {}
    for o in doc_nhieu("subs.jsonl"):
        sub_theo_topic[o.get("__topic", "?")] = o.get("Subscriptions") or []

    dich = sorted({
        x for a in thay_alarm.values()
        for x in (a.get("AlarmActions") or []) + (a.get("OKActions") or [])
        if x.startswith("arn:aws:sns:")
    })

    for t in dich:
        if t not in sub_theo_topic:
            # Doc khong duoc != khong co ai. Thuong gap khi topic o ACCOUNT
            # KHAC - va luc do con mot cau hoi nua chua tra loi: policy cua
            # topic do co cho alarm ben nay publish khong.
            print(f"    {t}")
            print("        khong doc duoc danh sach dang ky (topic o account khac?)")
            canh.append(
                f"khong doc duoc nguoi dang ky cua {t}.\n"
                "        Nen KHONG ket luan duoc la co ai nhan hay khong. Neu topic nam o\n"
                "        ACCOUNT KHAC thi con mot cau nua chua tra loi: resource policy ben\n"
                "        do co cho cloudwatch.amazonaws.com tu account nay publish khong -\n"
                "        thieu thi alarm doi mau va SNS tu choi, im lang."
            )
            continue

        subs = sub_theo_topic[t]
        cho_xac_nhan = [s for s in subs if s.get("SubscriptionArn") == "PendingConfirmation"]
        da_xac_nhan = len(subs) - len(cho_xac_nhan)
        print(f"    {t}")
        print(f"        {da_xac_nhan} da xac nhan, {len(cho_xac_nhan)} cho xac nhan")

        if not subs:
            loi.append(
                f"topic {t} KHONG co ai dang ky.\n"
                "        Alarm ban vao no thanh cong va message di vao hu khong. Moi lop\n"
                "        deu xanh: alarm co action, SNS nhan message, Terraform khong co\n"
                "        gi de noi."
            )
        elif da_xac_nhan == 0:
            loi.append(
                f"topic {t} co {len(cho_xac_nhan)} dang ky nhung TAT CA con o\n"
                "        PendingConfirmation - chua ai bam link trong thu SNS gui, nen\n"
                "        chua ai nhan duoc gi.\n"
                "        Terraform khong noi duoc dieu nay: no bao tao thanh cong va plan\n"
                "        ra 'No changes' o ca hai trang thai.\n"
                "        Kiem lai hop thu (ke ca muc spam) roi bam link xac nhan."
            )
        elif cho_xac_nhan:
            canh.append(
                f"topic {t} co {len(cho_xac_nhan)} dang ky con cho xac nhan:\n"
                + "".join(
                    f"          {s.get('Endpoint', '?')}\n" for s in cho_xac_nhan
                )
                + f"        {da_xac_nhan} dia chi khac DA xac nhan nen canh bao van den duoc -\n"
                "        nhung nhung dia chi tren thi khong."
            )

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
        print("    Va day la mot phep do THAT: list-rule-groups DOC DUOC roi tra ve")
        print("    danh sach rong, khong phai mot lenh hong.")
        if not ARN_ROLE:
            ####################################
            # KHONG ASSUME -> KHONG BIET DANG DOC ACCOUNT NAO CO DUNG KHONG
            #
            # Khi co ARN, account dich nam ngay trong ARN nen "rong" la rong
            # o DUNG account. Khong co ARN thi script doc bang danh tinh dang
            # co trong shell - co the la account mang (nguoi chay tay dang
            # nhap SSO vao do), va cung co the la account management (buoc
            # verify cua pipeline). Hai truong hop cho ra cung mot danh sach
            # rong voi hai y nghia nguoc nhau.
            #
            # Script KHONG doan duoc, nen no noi ra thay vi im.
            ####################################
            print()
            print(f"    {VANG}Nhung: khong co ARN nen script khong biet account o tren")
            print(f"    CO PHAI account mang hay khong.{HET} Neu no la account khac thi")
            print("    'rong' chi co nghia la layer nay khong o day - khong phai no")
            print("    khong ton tai. Doi chieu so account o dau bao cao.")
else:
    print("── Ky vong: network DA duoc dung")
    if not arn_rg and doc_duoc:
        # Khong co ARN thi "khong thay" co them mot nguyen nhan nua - dang
        # doc account khac - va script khong phan biet duoc. Neu ep no thanh
        # mot LOI rieng ve ARN thi lai doan sai cho nguoi chay tay dang dung
        # san trong account mang (da mac dung loi do mot lan).
        them = "" if ARN_ROLE else (
            "\n        VA: khong co ARN nen co the dang doc NHAM ACCOUNT - so account o"
            "\n        dau bao cao phai la account mang. Truyen ARN de bo kha nang nay."
        )
        loi.append(
            "KHONG co rule group nao co hau to -ops-east-west.\n"
            "        Stage tuong lua dang bat, nen day la thieu that - hoac rule group\n"
            "        chua duoc tao, hoac dang o region khac." + them
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

        ####################################
        # CHE DO: "DUOC DOC TOI" VAN CHUA LA "CHAN DUOC"
        #
        # Mot rule group duoc policy tham chieu day du, luat nap dung, ma
        # hanh dong MAC DINH cua policy la alert thi khong luong nao bi
        # chan: luat `pass` chi cho qua nhung thu da duoc cho qua, con thu
        # khong khop rule cung di qua binh thuong. Firewall chi GHI LOG.
        #
        # Layer co san check "firewall_mode_makes_rules_meaningful" noi
        # dung dieu nay. Nhung no doc local.hub.firewall.mode - mot gia tri
        # tu STATE cua layer cha, tuc mot LOI KHAI. Doi
        # StatefulDefaultActions o console thi check do van xanh trong khi
        # tuong lua that hanh xu khac.
        #
        # Cung ly do phep kiem "duoc doc toi" ton tai du da co
        # check "rule_group_is_referenced": check doc lo khai, verify doc
        # AWS. Va cung ho voi loi 126 - "policy chua statement" khac
        # "guardrail chan duoc".
        #
        # CANH BAO chu khong LOI: alert truoc drop la lo trinh co chu dich,
        # va next_steps cua layer cha ghi ro "chuyen sang drop khi da doc
        # du log UNMATCHED east-west".
        ####################################
        for p in ten_policy.get(arn_rg, []):
            hd = mac_dinh_policy.get(p, [])
            co_chan = any("drop" in x or "reject" in x for x in hd)
            print(f"        {p}: mac dinh = {', '.join(hd) or 'khong khai'}")
            if not co_chan:
                canh.append(
                    f"policy {p} tham chieu rule group nhung hanh dong MAC DINH khong co\n"
                    f"        drop/reject ({', '.join(hd) or 'khong khai'}).\n"
                    f"        Nen {so_luat if so_luat is not None else '?'} dong luat duoc nap ma KHONG chan gi:"
                    " luat `pass` chi cho\n"
                    "        qua thu da duoc cho qua, con thu khong khop rule cung di qua\n"
                    "        binh thuong. Tuong lua dang GHI LOG, khong dang loc.\n"
                    "        Day la trang thai dung khi con do duong - va no cung nghia la\n"
                    "        chua kiem chung duoc rule nao that su can thiet. Chuyen sang\n"
                    "        drop o LAYER CHA (var.firewall_mode) khi da doc du log UNMATCHED."
                )

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
