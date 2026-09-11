#!/usr/bin/env bash
#
# Test bo phan loai THAT / NOI cua lint.sh.
#
# VI SAO CAN MOT FILE TEST RIENG, KHI DA CO lint.sh
#
# lint.sh chay sach tren catalog hien tai. Dieu do KHONG chung minh
# rang no bat duoc mot thay doi noi long - no chi chung minh rang
# catalog hien tai khong co thay doi nao. Mot bo phan loai chua bao gio
# NOI "co" la mot bo phan loai chua bao gio duoc kiem.
#
# Day dung la khuyet diem da lap lai bay lan trong doc 22: mot phep loc
# khong khop tra ve rong, va rong bi doc thanh mot cau tra loi. O day
# no se co dang "lint xanh, nen khong ai noi long guardrail" - trong
# khi su that co the la lint khong bao gio bat duoc gi.
#
# Cach test: chup catalog hien tai thanh "ban dang gan o AWS", roi sua
# catalog theo tung kieu NOI va doi lint phai thoat 1.
#
# Khong goi AWS. Khong can credential.
########################################

set -uo pipefail
cd "$(dirname "$0")" || exit 1

PROJECT="${PROJECT:-qh11-lz}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

R="\033[31m"; G="\033[32m"; N="\033[0m"
dat=0
truot=0

########################################
# Chup catalog hien tai thanh ban "dang gan o AWS"
#
# Chi dung Sid / Action / NotAction / Resource - dung nhung truong ma
# bo phan loai doc. Condition chi can CO hay KHONG.
#
# QUAN TRONG: ban chup phai giong AWS, KHONG giong catalog.
#
#   ${partition} -> "aws"              (AWS luu dang da render)
#   "Workloads/Production" -> "Production"  (AWS tra ve TEN OU)
#
# Ban dau ham nay chep thang tu catalog, nen fixture mang dung nhung
# sai lech ma lint cung mang - va 22 test deu xanh trong khi lint bao
# dong gia tren hai statement co that. Mot fixture dung tu CUNG NGUON
# voi code can kiem thi khong the phat hien lech bieu dien.
########################################
chup() {
  CAT="$1" OUT="$2" PROJECT="$PROJECT" python3 - <<'PY'
import json, os, yaml
doc = yaml.safe_load(open(os.environ["CAT"]))
out = {}
for p in doc["policies"]:
    stmts = []
    for s in p.get("statements") or []:
        def R(v):
            if isinstance(v, list): return [R(x) for x in v]
            return v.replace("${partition}", "aws") if isinstance(v, str) else v

        d = {"Sid": s["sid"], "Effect": s["effect"], "Resource": R(s["resource"])}
        if s.get("action") is not None:     d["Action"] = R(s["action"])
        if s.get("not_action") is not None: d["NotAction"] = R(s["not_action"])
        if s.get("condition"):              d["Condition"] = {"_": "_"}
        stmts.append(d)
    ten = f"{os.environ['PROJECT']}-{p['name'].replace('_', '-')}"
    out[ten] = {
        "content": json.dumps({"Version": "2012-10-17", "Statement": stmts}),
        # AWS tra ve TEN OU, khong phai duong dan.
        "targets": [str(x).split("/")[-1] for x in (p.get("targets") or [])],
    }
json.dump(out, open(os.environ["OUT"], "w"))
PY
}

# sua <ten test> <ma thoat mong doi> <bieu thuc python> [co cho lint.sh]
sua() {
  local ten="$1" mong="$2" code="$3"
  shift 3
  local co=("$@")
  local cat="$TMP/scp.yaml"
  cp catalog/scp.yaml "$cat"

  CAT="$cat" python3 - "$code" <<'PY'
import sys, yaml, os
doc = yaml.safe_load(open(os.environ["CAT"]))
P = {p["name"]: p for p in doc["policies"]}
def S(pol, sid):
    for s in P[pol]["statements"]:
        if s["sid"] == sid: return s
    raise KeyError(sid)
exec(sys.argv[1])
yaml.safe_dump(doc, open(os.environ["CAT"], "w"), sort_keys=False, allow_unicode=True)
PY

  local ra
  ra=$(CATALOG_DIR="$TMP" AWS_DUMP="$TMP/aws.json" PROJECT="$PROJECT" \
    ./lint.sh "${co[@]+"${co[@]}"}" 2>&1)
  local ma=$?

  if [[ "$ma" == "$mong" ]]; then
    printf "  ${G}✓${N} %s  (thoat %s)\n" "$ten" "$ma"
    dat=$((dat + 1))
  else
    printf "  ${R}✗${N} %s  (thoat %s, mong doi %s)\n" "$ten" "$ma" "$mong"
    echo "$ra" | sed 's/^/        /'
    truot=$((truot + 1))
  fi
}

########################################
echo
echo "════════════════════════════════════════════"
echo " Test bo phan loai THAT / NOI"
echo "════════════════════════════════════════════"
echo

chup catalog/scp.yaml "$TMP/aws.json"

# Doi chung: khong sua gi -> phai sach.
sua "khong doi gi                     -> sach" 0 "pass"

echo
echo "── NOI: phai thoat 1 ──"

sua "xoa mot statement" 1 \
  "P['prod_guard']['statements'] = [s for s in P['prod_guard']['statements'] if s['sid'] != 'ProtectS3Recovery']"

sua "thu hep danh sach action" 1 \
  "S('prod_guard','ProtectEncryptionKeys')['action'] = ['kms:ScheduleKeyDeletion']"

sua "thu hep resource" 1 \
  "S('prod_guard','ProtectS3Recovery')['resource'] = ['arn:aws:s3:::chi-mot-bucket']"

sua "them condition vao Deny truoc do khong co" 1 \
  "S('prod_guard','ProtectEncryptionKeys')['condition'] = 'exempt_roles'"

sua "go policy khoi mot OU" 1 \
  "P['network_lock']['targets'] = ['Workloads']"

sua "doi Action thanh NotAction" 1 \
  "s = S('prod_guard','ProtectEncryptionKeys'); s['not_action'] = s.pop('action')"

sua "xoa han mot policy khoi catalog" 1 \
  "doc['policies'] = [p for p in doc['policies'] if p['name'] != 'prod_guard']"

echo
echo "── NOI mot statement locked: phai thoat 1 KE CA khi co loosen ──"

sua "xoa statement locked, co khoi loosen day du" 1 \
  "S('baseline','ProtectAuditTrail')['action'] = ['cloudtrail:StopLogging']; S('baseline','ProtectAuditTrail')['loosen'] = {'ticket':'X-1','reason':'thu','approved_by':'a@b.c','expires':'2099-01-01'}"

echo
echo "── NOI co khai bao day du: phai sach ──"

sua "thu hep action + khoi loosen day du" 0 \
  "s = S('prod_guard','ProtectEncryptionKeys'); s['action'] = ['kms:ScheduleKeyDeletion']; s['loosen'] = {'ticket':'SEC-1','reason':'thu nghiem','approved_by':'a@b.c','expires':'2099-01-01'}"

sua "loosen thieu approved_by" 1 \
  "s = S('prod_guard','ProtectEncryptionKeys'); s['action'] = ['kms:ScheduleKeyDeletion']; s['loosen'] = {'ticket':'SEC-1','reason':'thu','expires':'2099-01-01'}"

sua "loosen het han (che do thuong: canh bao, khong loi)" 0 \
  "s = S('prod_guard','ProtectEncryptionKeys'); s['action'] = ['kms:ScheduleKeyDeletion']; s['loosen'] = {'ticket':'SEC-1','reason':'thu','approved_by':'a@b.c','expires':'2020-01-01'}"

# --expiry la che do job hang dem dung. Neu no KHONG thoat 1 tren mot
# khoi loosen het han thi job do chay xanh mai mai, va mot ngoai le da
# qua han se song vinh vien ma khong ai duoc bao.
sua "loosen het han + --expiry (phai thoat 1)" 1 \
  "s = S('prod_guard','ProtectEncryptionKeys'); s['action'] = ['kms:ScheduleKeyDeletion']; s['loosen'] = {'ticket':'SEC-1','reason':'thu','approved_by':'a@b.c','expires':'2020-01-01'}" \
  --expiry

sua "loosen CON HAN + --expiry (phai sach)" 0 \
  "s = S('prod_guard','ProtectEncryptionKeys'); s['action'] = ['kms:ScheduleKeyDeletion']; s['loosen'] = {'ticket':'SEC-1','reason':'thu','approved_by':'a@b.c','expires':'2099-01-01'}" \
  --expiry

echo
echo "── THAT: phai sach, khong can khai bao gi ──"

sua "them mot Deny moi" 0 \
  "P['prod_guard']['statements'].append({'sid':'ChanThuMoi','effect':'Deny','action':['fsx:DeleteFileSystem'],'resource':'*','reason':'thu nghiem that'})"

sua "mo rong danh sach action" 0 \
  "S('prod_guard','ProtectEncryptionKeys')['action'].append('kms:DeleteAlias')"

sua "them mot policy moi" 0 \
  "doc['policies'].append({'name':'thu_moi','description':'thu','targets':['Sandbox'],'statements':[{'sid':'ThuMoi','effect':'Deny','action':['iot:*'],'resource':'*','reason':'thu nghiem'}]})"

echo
echo "── Schema: phai thoat 1 ──"

sua "sid trung" 1 \
  "P['prod_guard']['statements'].append(dict(S('baseline','DenyIamUserCreation')))"

sua "khai ca action va not_action" 1 \
  "S('prod_guard','ProtectEncryptionKeys')['not_action'] = ['sts:*']"

sua "thieu reason" 1 \
  "del S('prod_guard','ProtectEncryptionKeys')['reason']"

sua "condition khong co trong bang builder" 1 \
  "S('prod_guard','ProtectEncryptionKeys')['condition'] = 'khong_ton_tai'"

sua "locked va loosen cung luc" 1 \
  "S('baseline','ProtectAuditTrail')['loosen'] = {'ticket':'X','reason':'y','approved_by':'a@b.c','expires':'2099-01-01'}"

########################################
echo
echo "── Ten project SAI: phai thoat 1, KHONG duoc bao 'sach' ──"
#
# Bo phan loai coi "khong thay policy o AWS" la policy MOI, tuc THAT,
# tuc khong loi. Nen mot ten project sai lam MOI policy thanh "moi" va
# lint se bao 0 thay doi NOI - mot lan PASS GIA tren mot catalog khong
# he duoc so. Day la loi 116.
########################################

ten_project() { # <ten test> <ma thoat mong doi> <ten project> [bien=gia tri]
  local ten="$1" mong="$2" du_an="$3"
  shift 3
  local cat="$TMP/scp.yaml"
  cp catalog/scp.yaml "$cat"

  local ra
  ra=$(CATALOG_DIR="$TMP" AWS_DUMP="$TMP/aws.json" PROJECT="$du_an" \
    env ${1+"$@"} ./lint.sh 2>&1)
  local ma=$?

  if [[ "$ma" == "$mong" ]]; then
    printf "  ${G}✓${N} %s  (thoat %s)\n" "$ten" "$ma"
    dat=$((dat + 1))
  else
    printf "  ${R}✗${N} %s  (thoat %s, mong doi %s)\n" "$ten" "$ma" "$mong"
    echo "$ra" | sed 's/^/        /'
    truot=$((truot + 1))
  fi
}

ten_project "ten project sai            -> thoat 1" 1 "du-an-khong-ton-tai"
ten_project "ten project dung           -> sach"    0 "$PROJECT"

# LAN_DAU=yes la cach noi ro "chua tung apply SCP nao". Khong co no thi
# lan apply that su dau tien bi chan - co y: mot lan chan sai lam nguoi
# ta doc thong bao, con mot lan PASS gia thi khong.
ten_project "0 khop + LAN_DAU=yes      -> sach"     0 "du-an-khong-ton-tai" LAN_DAU=yes

########################################
echo
echo "── Nguon ten project ──"
#
# TRICH ham doc_project() THAT ra khoi lint.sh chu khong chep lai no.
# Mot ban chep chi chung minh ban chep tu nhat quan - do la bai hoc cua
# loi 115, khi fixture dung tu cung nguon voi code va 22 test deu xanh
# tren mot loi that.
########################################

sed -n '/^doc_project() {/,/^}/p' lint.sh >"$TMP/doc_project.sh"
if [[ ! -s "$TMP/doc_project.sh" ]]; then
  printf "  ${R}✗${N} khong trich duoc doc_project() tu lint.sh - ham bi doi ten?\n"
  truot=$((truot + 1))
fi

nguon() { # <ten test> <mong doi "gia tri|nguon"> <thu muc chay> [BIEN=gia tri ...]
  local ten="$1" mong="$2" dir="$3"
  shift 3
  local ra
  ra=$(
    cd "$dir" || exit 1
    env -u PROJECT -u TF_VAR_project ${1+"$@"} bash -c "
      set -uo pipefail
      source '$TMP/doc_project.sh'
      NGUON_PROJECT=
      if doc_project; then
        printf '%s|%s' \"\$PROJECT\" \"\$NGUON_PROJECT\"
      else
        printf '|KHONG'
      fi"
  )

  if [[ "$ra" == "$mong" ]]; then
    printf "  ${G}✓${N} %s  (%s)\n" "$ten" "$ra"
    dat=$((dat + 1))
  else
    printf "  ${R}✗${N} %s  (duoc '%s', mong doi '%s')\n" "$ten" "$ra" "$mong"
    truot=$((truot + 1))
  fi
}

mkdir -p "$TMP/co-tfvars" "$TMP/trong" "$TMP/chi-comment" "$TMP/ten-gan-giong"
printf 'region = "ap-southeast-1"\nproject     = "tu-tfvars"\n' \
  >"$TMP/co-tfvars/terraform.tfvars"
printf '# project = "bi-comment"\n' >"$TMP/chi-comment/terraform.tfvars"
printf 'project_name = "khong-phai-cai-nay"\n' >"$TMP/ten-gan-giong/terraform.tfvars"

nguon "doc tu terraform.tfvars" "tu-tfvars|terraform.tfvars" "$TMP/co-tfvars"

# Bien PROJECT phai THANG tfvars: nguoi chay tay can ghi de duoc.
nguon "bien PROJECT thang tfvars" "tu-bien|bien PROJECT" "$TMP/co-tfvars" \
  PROJECT=tu-bien

# Neo `^[[:space:]]*project` phai loai dong comment. Neu no khop thi
# ket qua se la "bi-comment|terraform.tfvars".
nguon "dong comment khong tinh" "tu-env|TF_VAR_project" "$TMP/chi-comment" \
  TF_VAR_project=tu-env

# `project_name = ...` khong duoc khop `project = ...`.
nguon "project_name khong khop" "|KHONG" "$TMP/ten-gan-giong"

nguon "khong co nguon nao   -> KHONG" "|KHONG" "$TMP/trong"

echo
echo "════════════════════════════════════════════"
if [[ "$truot" == "0" ]]; then
  printf " ${G}%s dat / 0 truot${N}\n" "$dat"
  echo "════════════════════════════════════════════"
  exit 0
fi
printf " ${R}%s dat / %s truot${N}\n" "$dat" "$truot"
echo "════════════════════════════════════════════"
exit 1
