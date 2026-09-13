#!/usr/bin/env bash
#
# Kiem Identity Center DANG THAT o AWS - khong doc Terraform state.
#
#   ./kiem-quyen.sh
#
# Khong tham so. TU_THU_MUC=<dir> de doc JSON co san (test offline).
#
# PHEP KIEM LOG KHONG O DAY: no chung cho moi pipeline nen nam o
# ../ops-gate/kiem-log.sh, va buildspec-verify.yml goi no LUON sau lenh
# nay.
#
# ======================================================================
# VI SAO CAN, KHI apply DA IN RA id CUA ASSIGNMENT
#
# Ban dau toi de KHONG co verify cho pipeline nay, ly do ghi la "doc lai
# assignment thi luon xanh nhung khong tra loi duoc cau hoi that: nguoi
# trong group co vao duoc account khong".
#
# Ly do do SAI o hai cho:
#
#   1. Identity Center nam o ACCOUNT MANAGEMENT. sso:List* va
#      identitystore:List* doc duoc het tu day - khong can assume.
#   2. "Doc lai thi luon xanh" la mot lap luan giet luon verify cua SCP,
#      noi no CO gia tri. Mot phep doc chi vo ich khi no khong the FAIL.
#
# Va no CO the fail, o nhung cho duoi day - tat ca deu la kieu hong IM
# LANG, tuc khong co trieu chung nao ngoai viec ai do khong lam duoc viec.
#
# ======================================================================
# BON CAU HOI, VA CHUNG DEU CO THE TRA LOI "KHONG"
#
#   permission set khong co quyen nao   ai vao duoc cung khong lam gi duoc
#   group khong co assignment nao       nguoi trong group vao duoc 0 account
#   user khong thuoc group nao          dang nhap duoc, thay 0 thu
#   group khong co ai                   mot cai hop rong, va no trong nhu
#                                       mot nhom dang hoat dong
#
# Ba cai dau la hong that. Cai thu tu la CANH BAO: mot group rong co the
# la co y (vua tao, cho nguoi vao) hoac la mot ngoai le da het han.
#
# ======================================================================
# CAI KHONG KIEM DUOC O DAY, VA PHAI NOI RO
#
# Mot assignment ton tai khong chung minh nguoi trong group VAO DUOC
# account: Identity Center con phai sinh role AWSReservedSSO_<set>_<hash>
# o account dich, va viec do khong tuc thi.
#
# Doc thu do doi mot phien o ACCOUNT DICH - thu buoc verify khong co. Nen
# phep thu that van la bang tay:
#
#   aws sso login --profile <ten>
#   aws sts get-caller-identity --profile <ten>
#   -> ARN phai co dang assumed-role/AWSReservedSSO_<set>_<hash>/<user>
#
# Ghi ra de khong ai doc mau xanh cua script nay thanh "moi nguoi vao
# duoc".
#
set -uo pipefail

XANH=$'\033[32m'; DO=$'\033[31m'; VANG=$'\033[33m'; HET=$'\033[0m'

if [[ $# -gt 0 ]]; then
  echo "Script nay khong nhan tham so (nhan duoc: $*)."
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
  aws sso-admin list-instances --region "$REGION" --output json \
    > "$D/instances.json" 2>"$D/instances.err"

  read -r ARN STORE <<<"$(python3 - "$D/instances.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
i = d.get("Instances") or []
if i:
    print(i[0]["InstanceArn"], i[0]["IdentityStoreId"])
PY
  )"

  if [[ -n "${ARN:-}" ]]; then
    aws sso-admin list-permission-sets --instance-arn "$ARN" \
      --region "$REGION" --output json > "$D/sets.json" 2>"$D/sets.err"

    for PS in $(python3 - "$D/sets.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for a in d.get("PermissionSets", []):
    print(a)
PY
    ); do
      # Ten file dung phan cuoi cua ARN: "ps-<hash>".
      K="${PS##*/}"
      aws sso-admin describe-permission-set --instance-arn "$ARN" \
        --permission-set-arn "$PS" --region "$REGION" --output json \
        > "$D/set-$K.json" 2>"$D/set-$K.err"
      aws sso-admin list-managed-policies-in-permission-set --instance-arn "$ARN" \
        --permission-set-arn "$PS" --region "$REGION" --output json \
        > "$D/mp-$K.json" 2>"$D/mp-$K.err"
      aws sso-admin get-inline-policy-for-permission-set --instance-arn "$ARN" \
        --permission-set-arn "$PS" --region "$REGION" --output json \
        > "$D/inline-$K.json" 2>"$D/inline-$K.err"
      aws sso-admin list-accounts-for-provisioned-permission-set --instance-arn "$ARN" \
        --permission-set-arn "$PS" --region "$REGION" --output json \
        > "$D/acc-$K.json" 2>"$D/acc-$K.err"
    done
  fi

  if [[ -n "${STORE:-}" ]]; then
    aws identitystore list-groups --identity-store-id "$STORE" \
      --region "$REGION" --output json > "$D/groups.json" 2>"$D/groups.err"
    aws identitystore list-users --identity-store-id "$STORE" \
      --region "$REGION" --output json > "$D/users.json" 2>"$D/users.err"

    for G in $(python3 - "$D/groups.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for g in d.get("Groups", []):
    print(g["GroupId"])
PY
    ); do
      aws identitystore list-group-memberships --identity-store-id "$STORE" \
        --group-id "$G" --region "$REGION" --output json \
        > "$D/mem-$G.json" 2>"$D/mem-$G.err"
    done
  fi
fi

########################################
# PHAN TICH
########################################
python3 - "$D" <<'PY'
import glob, json, os, sys

D = sys.argv[1]
XANH, DO, VANG, HET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"
loi, canh = [], []


def doc(ten):
    """(du_lieu, loi). PHAI tra ve ca hai - "rong", "AWS bao loi" va
    "JSON hong" la ba viec khac nhau."""
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
print("── Identity Center")

d, e = doc("instances.json")
if d is None or not (d.get("Instances") or []):
    print(f"  {DO}LOI{HET}  khong doc duoc instance Identity Center.")
    print(f"        {e or 'list-instances tra ve 0 instance'}")
    print("        Day KHONG phai 'khong co gi sai' - la KHONG KIEM DUOC.")
    sys.exit(1)

inst = d["Instances"][0]
print(f"    instance     {inst['InstanceArn']}")
print(f"    identity store {inst['IdentityStoreId']}")

####################################
# 1. PERMISSION SET - CO QUYEN NAO KHONG, GAN VAO ACCOUNT NAO
#
# Mot permission set khong co managed policy lan inline policy la mot cai
# ten: ai vao duoc qua no cung khong lam gi duoc. Va no KHONG co trieu
# chung - nguoi dung thay set do trong portal, bam vao, va gap Access
# Denied o moi thao tac.
####################################
print()
print("── Permission set")
d, e = doc("sets.json")
if d is None:
    loi.append(f"khong doc duoc list-permission-sets.\n        {e}")
    sets = []
else:
    sets = d.get("PermissionSets") or []
    if not sets:
        loi.append(
            "0 permission set. Doc duoc va rong - nen day KHONG phai loi doc:\n"
            "        layer chua duoc apply, hoac apply vao instance khac."
        )

tong_gan = 0
for arn in sorted(sets):
    k = arn.rsplit("/", 1)[-1]
    ds, e1 = doc(f"set-{k}.json")
    ten = (ds or {}).get("PermissionSet", {}).get("Name", k)

    mp, _ = doc(f"mp-{k}.json")
    il, _ = doc(f"inline-{k}.json")
    ac, _ = doc(f"acc-{k}.json")

    so_mp = len((mp or {}).get("AttachedManagedPolicies") or [])
    co_il = bool((il or {}).get("InlinePolicy"))
    accs = (ac or {}).get("AccountIds") or []
    tong_gan += len(accs)

    print(f"    {ten:<24} {so_mp} managed, inline={'co' if co_il else 'khong'}, {len(accs)} account")

    if so_mp == 0 and not co_il:
        loi.append(
            f"permission set {ten} KHONG co managed policy lan inline policy.\n"
            "        Ai vao duoc qua no cung khong lam gi duoc, va khong co trieu\n"
            "        chung: nguoi dung thay set do trong portal roi gap Access Denied\n"
            "        o moi thao tac."
        )

####################################
# 2. GROUP - CO ASSIGNMENT KHONG, CO AI KHONG
#
# Mot group khong co assignment nao: nguoi trong do dang nhap duoc va vao
# duoc 0 account. Day la kieu hong im lang nhat trong ca layer - khong ai
# bao loi, chi la mot nguoi khong lam duoc viec.
####################################
print()
print("── Group")
d, e = doc("groups.json")
groups = []
if d is None:
    loi.append(f"khong doc duoc list-groups.\n        {e}")
else:
    groups = d.get("Groups") or []
    if not groups:
        loi.append("0 group trong identity store. Doc duoc va rong.")

# Group nao co assignment: tap principal id lay tu list-accounts... khong
# co, nen suy tu so account cua tung permission set la khong du. Thay vao
# do dem thanh vien va bao rieng - doc duoc va dung.
thanh_vien = {}
for f in sorted(glob.glob(os.path.join(D, "mem-*.json"))):
    gid = os.path.basename(f)[4:-5]
    dd, ee = doc(os.path.basename(f))
    if dd is None:
        loi.append(f"khong doc duoc thanh vien cua group {gid}.\n        {ee}")
        continue
    thanh_vien[gid] = dd.get("GroupMemberships") or []

for g in sorted(groups, key=lambda x: x.get("DisplayName", "")):
    gid, ten = g["GroupId"], g.get("DisplayName", g["GroupId"])
    tv = thanh_vien.get(gid)
    if tv is None:
        print(f"    {ten:<24} (khong doc duoc thanh vien)")
        continue
    print(f"    {ten:<24} {len(tv)} nguoi")
    if not tv:
        canh.append(
            f"group {ten} KHONG co ai. Co the co y (vua tao, cho nguoi vao) hoac\n"
            "        la mot ngoai le da het han - mot cai hop rong trong nhu mot nhom\n"
            "        dang hoat dong."
        )

####################################
# 3. USER - CO THUOC GROUP NAO KHONG
#
# Mot user khong thuoc group nao thi dang nhap duoc va thay 0 thu. Trieu
# chung la "toi khong thay account nao", khong phai mot loi.
####################################
print()
print("── User")
d, e = doc("users.json")
if d is None:
    loi.append(f"khong doc duoc list-users.\n        {e}")
else:
    users = d.get("Users") or []
    co_group = {m["MemberId"]["UserId"] for tv in thanh_vien.values() for m in tv}
    for u in sorted(users, key=lambda x: x.get("UserName", "")):
        uid, ten = u["UserId"], u.get("UserName", u["UserId"])
        so = sum(1 for tv in thanh_vien.values() for m in tv if m["MemberId"]["UserId"] == uid)
        print(f"    {ten:<24} {so} group")
        if uid not in co_group:
            loi.append(
                f"user {ten} KHONG thuoc group nao - dang nhap duoc va thay 0 thu.\n"
                "        Trieu chung la \"toi khong thay account nao\", khong phai mot loi."
            )

print()
print(f"    Tong: {tong_gan} lan mot permission set duoc cap phat vao mot account")

####################################
# CAI KHONG KIEM DUOC - NOI RO, KHONG DE MAU XANH TU NOI HO
####################################
print()
print("  Script nay KHONG chung minh duoc nguoi trong group VAO DUOC account:")
print("  Identity Center con phai sinh role AWSReservedSSO_<set>_<hash> o account")
print("  dich, va doc thu do doi mot phien o ACCOUNT DICH. Phep thu that:")
print("    aws sso login --profile <ten> && aws sts get-caller-identity --profile <ten>")

print()
for c in canh:
    print(f"  {VANG}CANH BAO{HET} {c}")
for l in loi:
    print(f"  {DO}LOI{HET}  {l}")

print()
print(f"  Da kiem: {len(sets)} permission set, {len(groups)} group.")
if loi:
    print(f"  {DO}{len(loi)} loi{HET}, {len(canh)} canh bao.")
    sys.exit(1)
if canh:
    print(f"  {VANG}{len(canh)} canh bao{HET}, 0 loi.")
    sys.exit(0)
print(f"  {XANH}Moi permission set co quyen, moi user co group.{HET} 0 canh bao.")
PY
