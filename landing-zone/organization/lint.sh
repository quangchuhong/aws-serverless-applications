#!/usr/bin/env bash
#
# Kiem catalog/scp.yaml TRUOC KHI cham vao Terraform.
#
# BA CHE DO
#
#   ./lint.sh            offline. Khong can AWS, khong can terraform
#                        init, khong goi mang. Duoi mot giay.
#   ./lint.sh --aws      them phep phan biet THAT vs NOI, doi chieu
#                        voi policy DANG GAN THAT o AWS.
#   ./lint.sh --expiry   khoi `loosen` het han thi thoat 1. Danh cho
#                        job chay theo lich.
#
# --strict lam canh bao thanh loi. CI dung --strict.
#
# --------------------------------------------------------------
# VI SAO CAN, KHI TERRAFORM DA CO check
#
# check trong Terraform chi chay khi ai do co state, co credential, va
# chiu doi `terraform init` + `plan`. Nguoi mo PR de them mot dong Deny
# thuong khong co ca ba. Neu vong phan hoi ngan nhat cua ho la "doi CI
# bon phut", ho se doan thay vi kiem.
#
# Va co nhung thu check KHONG bat duoc:
#
#   1. THAT hay NOI. check khong doc duoc policy dang gan o AWS, nen no
#      khong biet mot statement vua bi THU HEP. Voi SCP day la phep
#      kiem quan trong nhat - xem duoi.
#
#   2. Do dai 5120 ky tu. check doc duoc do dai, nhung luc no chay thi
#      apply sap xay ra roi. O day bat som hon mot vong.
#
#   3. YAML sai cu phap. Terraform bao loi tu yamldecode voi mot thong
#      bao khong noi dong nao.
#
# --------------------------------------------------------------
# THAT vs NOI - VA VI SAO NO LA TRUNG TAM
#
# O tan so cao, cai lam SCP an toan khong phai cong duyet ma la tinh
# BAT DOI XUNG:
#
#   THAT  them Deny moi, mo rong action/resource  -> chay tu do
#   NOI   xoa Deny, thu hep action/resource, them
#         condition, go policy khoi mot OU        -> phai khai bao
#
# Thiet chay tu do la dieu kien de tan so cao khong thanh ganh nang.
# Noi phai mang mot khoi `loosen` - va khoi do khong lam gi o AWS. No
# chi lam viec noi long HIEN RA TRONG DIFF cua PR, noi co nguoi doc
# duoc, thay vi hien trong mot ban plan CodeBuild noi nguoi ta bam tu
# dien thoai.
#
# SO VOI AWS, KHONG SO VOI GIT. So voi commit truoc thi bo sot nguoi
# sua tay trong console - va mot SCP bi noi trong console roi catalog
# "trung khop" chinh la truong hop can bat nhat.
#
# --------------------------------------------------------------
# ME CUNG BIET: lint khong render duoc Condition
#
# Noi dung Condition do scp-catalog.tf sinh, khong nam trong catalog.
# Nen o day so duoc:
#
#   co Condition <-> khong co Condition      (bat duoc)
#   noi dung Condition A -> noi dung B       (KHONG bat duoc)
#
# Truong hop thu hai la mot thay doi CODE trong scp-catalog.tf, di qua
# review code chu khong qua catalog. Ghi ra day de khong ai tuong lint
# nay phu het.
########################################

set -uo pipefail
cd "$(dirname "$0")" || exit 1

MODE_AWS=0
MODE_EXPIRY=0
STRICT=0
for a in "$@"; do
  case "$a" in
  --aws) MODE_AWS=1 ;;
  --expiry) MODE_EXPIRY=1 ;;
  --strict) STRICT=1 ;;
  *)
    echo "Tham so khong biet: $a"
    exit 2
    ;;
  esac
done

CATALOG="${CATALOG_DIR:-catalog}/scp.yaml"

if [[ ! -f "$CATALOG" ]]; then
  echo "Khong thay $CATALOG"
  exit 1
fi

########################################
# PHAN OFFLINE
#
# python3 chu khong phai yq/jq: yq khong co san o moi may, va logic o
# day (tap hop, so sanh, dem do dai) viet bang shell se dai hon va de
# sai hon.
########################################

PROJECT="${PROJECT:-}"
AWS_DUMP="${AWS_DUMP:-}"

# BAN CHUP THAY CHO AWS
#
# AWS_DUMP dat san trong moi truong thi dung luon, khong goi AWS. Hai
# cho dung:
#
#   1. CI khong co quyen doc organizations - mot buoc truoc do chup
#      lai, buoc nay so.
#   2. TEST bo phan loai that/noi. Mot bo phan loai chua tung chay la
#      mot gia dinh, khong phai mot lop bao ve. Xem test-lint.sh.
if [[ -n "${AWS_DUMP:-}" && -f "${AWS_DUMP}" ]]; then
  MODE_AWS=0
  echo "  (dung ban chup ${AWS_DUMP}, khong goi AWS)"
fi

if [[ "$MODE_AWS" == "1" ]]; then
  # Ten policy o AWS la "<project>-<ten catalog, _ thanh ->" - xem
  # resource aws_organizations_policy.scp trong scp.tf.
  if [[ -z "$PROJECT" ]]; then
    PROJECT=$(terraform output -raw project 2>/dev/null || echo "")
    # terraform output in canh bao ra STDOUT khi state rong - loi 114.
    case "$PROJECT" in
    *"Warning:"* | *"No outputs"* | *"╷"*) PROJECT="" ;;
    esac
  fi

  if [[ -z "$PROJECT" ]]; then
    echo "  ⚠ --aws can ten project de tim policy o AWS, nhung khong doc duoc."
    echo "    Chay: PROJECT=<ten> ./lint.sh --aws"
    echo "    Day KHONG phai 'khong co gi de so' - la CHUA SO DUOC."
    exit 1
  fi

  # Dump moi SCP dang co, kem target cua tung cai. Mot file JSON de
  # python doc - khong parse output cua aws trong bash.
  AWS_DUMP=$(mktemp)
  trap 'rm -f "$AWS_DUMP"' EXIT

  if ! aws organizations list-policies --filter SERVICE_CONTROL_POLICY \
    --query 'Policies[].[Id,Name]' --output text >"$AWS_DUMP.ids" 2>"$AWS_DUMP.err"; then
    echo "  ⚠ khong liet ke duoc SCP o AWS:"
    sed 's/^/      /' "$AWS_DUMP.err"
    echo "    Can quyen organizations:ListPolicies va chay o management account."
    exit 1
  fi

  echo "{" >"$AWS_DUMP"
  first=1
  while read -r pid pname; do
    [[ -z "$pid" ]] && continue
    content=$(aws organizations describe-policy --policy-id "$pid" \
      --query 'Policy.Content' --output text 2>/dev/null || echo "")
    [[ -z "$content" ]] && continue
    targets=$(aws organizations list-targets-for-policy --policy-id "$pid" \
      --query 'Targets[].Name' --output json 2>/dev/null || echo "[]")
    [[ "$first" == "0" ]] && echo "," >>"$AWS_DUMP"
    first=0
    printf '%s: {"content": %s, "targets": %s}' \
      "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$pname")" \
      "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$content")" \
      "$targets" >>"$AWS_DUMP"
  done < <(tr '\t' ' ' <"$AWS_DUMP.ids")
  echo "}" >>"$AWS_DUMP"
  rm -f "$AWS_DUMP.ids" "$AWS_DUMP.err"
fi

CATALOG="$CATALOG" AWS_DUMP="$AWS_DUMP" PROJECT="$PROJECT" \
  MODE_EXPIRY="$MODE_EXPIRY" STRICT="$STRICT" python3 <<'PY'
import json, os, re, sys, datetime

CATALOG   = os.environ["CATALOG"]
AWS_DUMP  = os.environ.get("AWS_DUMP") or ""
PROJECT   = os.environ.get("PROJECT") or ""
MODE_EXP  = os.environ.get("MODE_EXPIRY") == "1"
STRICT    = os.environ.get("STRICT") == "1"

try:
    import yaml
except ImportError:
    print("Thieu PyYAML. Cai: pip3 install pyyaml")
    sys.exit(2)

R = "\033[31m"; G = "\033[32m"; Y = "\033[33m"; N = "\033[0m"
loi = []; canh = []

def E(m): loi.append(m)
def W(m): canh.append(m)

try:
    doc = yaml.safe_load(open(CATALOG))
except yaml.YAMLError as e:
    print(f"{R}YAML sai cu phap{N}\n{e}")
    sys.exit(1)

if not isinstance(doc, dict) or "policies" not in doc:
    print(f"{R}Thieu khoa goc `policies`{N}")
    sys.exit(1)

POLICIES = doc["policies"]

# Ten builder condition hop le - PHAI khop bang scp_condition_json
# trong scp-catalog.tf. Lech thi Terraform chet voi "Invalid index",
# mot cau khong nhac gi toi catalog.
CONDITIONS = {
    "exempt_roles", "root_user_only", "s3_pab_automation",
    "region_lock", "network_account_exempt", "public_ip_on_launch",
}

# Hanh dong ma mot automation PHAI goi duoc. Chan chung di ma quen
# mien tru la tu khoa chinh minh - theo kieu KHONG sua duoc bang chinh
# automation do, vi lenh sua cung bi chan.
#
# NHUNG CHI KHI PRINCIPAL O ACCOUNT THANH VIEN.
#
# SCP khong ap dung cho principal o account MANAGEMENT, ke ca SCP gan
# vao Root. Nen mot pipeline chay o management - nhu ops-pipeline -
# khong bi nhung statement nay cham toi, va khong can mien tru.
#
# Canh bao nay van dang phat, vi tap automation se lon len: mot role o
# account security sua Config rule, mot role o account network sua
# route. Nhung no la mot CAU HOI ("principal cua ban o dau?"), khong
# phai mot menh lenh.
THIET_YEU = [
    "organizations:AttachPolicy", "organizations:DetachPolicy",
    "organizations:UpdatePolicy", "organizations:CreatePolicy",
    "organizations:DeletePolicy",
    "sts:AssumeRole",
    "cloudformation:CreateStackInstances", "cloudformation:UpdateStackSet",
    "s3:GetObject", "s3:PutObject",
    "dynamodb:PutItem", "dynamodb:DeleteItem",
]

def phu(mau, dich):
    """Mau action co phu hanh dong `dich` khong.

    "dynamodb:*" phu "dynamodb:PutItem"; "dynamodb:DeleteBackup" thi
    KHONG. Truoc day cho nay so tien to tho, nen bao dong gia o moi
    statement co chu "dynamodb:".
    """
    import fnmatch
    return fnmatch.fnmatchcase(dich, mau)

def as_list(v):
    if v is None: return []
    return v if isinstance(v, list) else [v]

########################################
# CHUAN HOA TRUOC KHI SO VOI AWS
#
# Catalog giu DANG KHAI ("arn:${partition}:ec2:..."), AWS giu DANG DA
# RENDER ("arn:aws:ec2:..."). So thang hai dang do thi moi statement
# co cho thay the deu bi bao la "Resource THU HEP" - mot bao dong gia
# ngay tren phep kiem quan trong nhat cua file nay.
#
# PARTITION mac dinh "aws". Dat PARTITION=aws-cn / aws-us-gov neu chay
# o partition khac.
PARTITION = os.environ.get("PARTITION") or "aws"

def render(v):
    """Dua mot gia tri catalog ve dang AWS se thay."""
    if isinstance(v, list):
        return [render(x) for x in v]
    if isinstance(v, str):
        return v.replace("${partition}", PARTITION)
    return v

def ten_target(t):
    """Ten target de SO SANH.

    Catalog viet duong dan ("Workloads/Production") vi local.ou_ids
    danh khoa nhu vay. AWS list-targets-for-policy tra ve TEN OU
    ("Production"). Lay doan cuoi, bo phan biet chu hoa - giong dung
    cach scp_target_id o scp.tf thu ca hai.
    """
    return str(t).split("/")[-1].strip().lower()

########################################
# 1. SCHEMA
########################################
seen_sid, seen_pol = {}, {}
flat = []

for p in POLICIES:
    for f in ("name", "description", "targets", "statements"):
        if not p.get(f):
            E(f"policy thieu `{f}`: {p.get('name', '(khong ten)')}")
    name = p.get("name", "?")
    if name in seen_pol:
        E(f"ten policy trung: {name}")
    seen_pol[name] = True

    for s in p.get("statements") or []:
        sid = s.get("sid", "(khong sid)")
        flat.append((p, s))

        for f in ("sid", "effect", "resource", "reason"):
            if not s.get(f):
                E(f"{name}/{sid}: thieu `{f}`")

        if sid in seen_sid:
            E(f"sid TRUNG giua {seen_sid[sid]} va {name}: {sid}"
              " - AWS khong tu choi dieu nay, no chi lam mot guardrail"
              " bien mat im lang")
        seen_sid[sid] = name

        has_a  = s.get("action") is not None
        has_na = s.get("not_action") is not None
        if has_a and has_na:
            E(f"{name}/{sid}: khai CA action VA not_action - AWS chi doc mot")
        if not has_a and not has_na:
            E(f"{name}/{sid}: khong khai action cung khong khai not_action")

        if s.get("effect") == "Allow":
            W(f"{name}/{sid}: effect Allow. SCP la TRAN quyen, khong cap"
              " quyen - Allow o day gan nhu luon la nham, va no khong"
              " mo them gi ca")

        c = s.get("condition")
        if c is not None and c not in CONDITIONS:
            E(f"{name}/{sid}: condition `{c}` khong co trong"
              f" scp_condition_json. Ten hop le: {', '.join(sorted(CONDITIONS))}")

        if s.get("locked") and s.get("loosen"):
            E(f"{name}/{sid}: locked: true thi KHONG khoi `loosen` nao du."
              " Muon doi thi sua code, bang tay, ngoai pipeline")

        # Deny + Action: nhung gi LIET KE bi chan.
        #
        # Deny + NotAction thi nguoc han: moi thu KHONG liet ke bi
        # chan. Truoc day cho nay gop ca hai, nen no bao
        # "chan organizations:*" cho mot statement dang MIEN TRU
        # organizations:* - sai nguoc hoan toan.
        if has_a:
            chan = sorted({
                d for mau in as_list(s.get("action"))
                for d in THIET_YEU if phu(mau, d)
            })
            if chan and not s.get("pipeline_scope"):
                W(f"{name}/{sid}: chan hanh dong automation can:"
                  f" {', '.join(chan)}."
                  " Neu automation goi chung nam o mot account THANH VIEN thi"
                  " role cua no phai vao scp_exempt_role_names."
                  " O account MANAGEMENT thi khong can - SCP khong ap dung o do."
                  " Da xem xet roi thi ghi `pipeline_scope: <ly do>` vao"
                  " statement de canh bao nay thoi lap lai")
        elif has_na:
            mien = as_list(s.get("not_action"))
            thieu = sorted({
                d for d in THIET_YEU
                if not any(phu(mau, d) for mau in mien)
            })
            if thieu and not s.get("pipeline_scope"):
                W(f"{name}/{sid}: Deny + NotAction chan MOI THU ngoai danh"
                  f" sach, va danh sach do THIEU: {', '.join(thieu)}."
                  " Kiem xem condition co gioi han pham vi du hep khong."
                  " Da xem xet roi thi ghi `pipeline_scope: <ly do>`")

########################################
# 2. GIOI HAN CUA AWS
#
# 5120 ky tu moi policy. O day chi UOC LUONG: noi dung Condition do
# scp-catalog.tf sinh, lint khong render duoc. Cong mot khoan du cho
# moi condition va bao dong som.
########################################
CHI_PHI_CONDITION = 180   # do tu exempt_roles voi 2 role - khoan du

for p in POLICIES:
    body = 0
    n_cond = 0
    for s in p.get("statements") or []:
        d = {"Sid": s.get("sid"), "Effect": s.get("effect"),
             "Resource": s.get("resource")}
        if s.get("action") is not None:     d["Action"] = s["action"]
        if s.get("not_action") is not None: d["NotAction"] = s["not_action"]
        body += len(json.dumps(d, separators=(",", ":")))
        if s.get("condition"):
            n_cond += 1
    uoc = body + 30 + n_cond * CHI_PHI_CONDITION   # 30 = vo Version/Statement

    if uoc > 5120:
        E(f"policy {p['name']}: uoc luong {uoc} ky tu, VUOT 5120."
          " Tach thanh hai policy - nhung nho toi da 4 policy mot OU")
    elif uoc > 4096:
        W(f"policy {p['name']}: uoc luong {uoc}/5120 ky tu (>80%)."
          " Con it cho de them Deny moi")

# Toi da 5 policy mot target, FullAWSAccess da chiem 1.
dem_target = {}
for p in POLICIES:
    if p.get("enabled") is False:
        continue
    for t in as_list(p.get("targets")):
        dem_target.setdefault(t, []).append(p["name"])

for t, ps in sorted(dem_target.items()):
    if len(ps) > 4:
        E(f"target {t} nhan {len(ps)} policy: {', '.join(ps)}."
          " AWS cho toi da 5, FullAWSAccess da chiem 1 -> con 4")

########################################
# 3. THAT hay NOI - can AWS
########################################
def tap_hanh_dong(st):
    """Tap action|not_action cua mot statement, da chuan hoa."""
    a = st.get("Action", st.get("action"))
    na = st.get("NotAction", st.get("not_action"))
    kind = "NotAction" if na is not None else "Action"
    v = na if na is not None else a
    return kind, set(render(as_list(v)))

def tap_resource(st):
    return set(render(as_list(st.get("Resource", st.get("resource")))))

noi_long = []          # (policy, sid, ly do)

if AWS_DUMP and os.path.exists(AWS_DUMP):
    aws = json.load(open(AWS_DUMP))

    for p in POLICIES:
        if p.get("enabled") is False:
            continue
        ten_aws = f"{PROJECT}-{p['name'].replace('_', '-')}"
        cu = aws.get(ten_aws)
        if cu is None:
            # Policy moi. Them mot policy la THAT - khong can khai bao.
            continue

        try:
            cu_stmts = json.loads(cu["content"]).get("Statement", [])
        except json.JSONDecodeError:
            E(f"{ten_aws}: khong doc duoc content tu AWS")
            continue
        cu_idx = {st.get("Sid"): st for st in cu_stmts if st.get("Sid")}
        moi_idx = {s["sid"]: s for s in (p.get("statements") or []) if s.get("sid")}

        # Statement bien mat = NOI.
        for sid in cu_idx:
            if sid not in moi_idx:
                noi_long.append((p["name"], sid, "statement bi XOA khoi catalog"))

        for sid, s in moi_idx.items():
            st_cu = cu_idx.get(sid)
            if st_cu is None:
                continue     # statement moi = THAT

            k_cu, a_cu = tap_hanh_dong(st_cu)
            k_moi, a_moi = tap_hanh_dong(s)

            if k_cu != k_moi:
                noi_long.append((p["name"], sid,
                    f"doi {k_cu} thanh {k_moi} - y nghia dao nguoc hoan toan"))
            else:
                mat = a_cu - a_moi
                if mat:
                    noi_long.append((p["name"], sid,
                        f"{k_moi} THU HEP, mat: {', '.join(sorted(mat))}"))

            mat_r = tap_resource(st_cu) - tap_resource(s)
            if mat_r:
                noi_long.append((p["name"], sid,
                    f"Resource THU HEP, mat: {', '.join(sorted(mat_r))}"))

            # Chi so duoc CO hay KHONG - noi dung Condition do
            # scp-catalog.tf sinh, lint khong render duoc.
            if "Condition" not in st_cu and s.get("condition"):
                noi_long.append((p["name"], sid,
                    f"THEM condition `{s['condition']}` vao mot Deny truoc day"
                    " khong co - day la mot ngoai le moi"))

        # Policy bi go khoi mot target = NOI.
        # So bang TEN OU, khong bang duong dan - xem ten_target().
        t_cu = {ten_target(t) for t in (cu.get("targets") or [])}
        t_moi = {ten_target(t) for t in as_list(p.get("targets"))}
        mat_t = {t for t in t_cu - t_moi if t != "root"}
        if mat_t and "root" not in t_moi:
            noi_long.append((p["name"], "(ca policy)",
                f"go khoi target: {', '.join(sorted(mat_t))}"))

    # Policy o AWS mang tien to project ma catalog khong con khai.
    tien_to = f"{PROJECT}-"
    ten_catalog = {f"{PROJECT}-{p['name'].replace('_', '-')}" for p in POLICIES}
    for ten in aws:
        if ten.startswith(tien_to) and ten not in ten_catalog:
            noi_long.append((ten, "(ca policy)",
                "co o AWS, KHONG con trong catalog - apply se xoa no"))

########################################
# 4. NOI PHAI CO KHAI BAO
########################################
def tim_stmt(pol, sid):
    for p in POLICIES:
        if p["name"] != pol: continue
        for s in p.get("statements") or []:
            if s.get("sid") == sid: return s
    return None

hom_nay = datetime.date.today()

for pol, sid, ly_do in noi_long:
    s = tim_stmt(pol, sid)

    if s is not None and s.get("locked"):
        E(f"{R}NOI mot statement locked{N}: {pol}/{sid} - {ly_do}."
          " locked la san ma pipeline khong ha duoc. Khong co `loosen` nao"
          " du. Muon doi thi sua code, bang tay, ngoai pipeline")
        continue

    lo = (s or {}).get("loosen") if s else None
    if not lo:
        E(f"{R}NOI ma khong khai bao{N}: {pol}/{sid} - {ly_do}."
          " Them khoi `loosen` voi ticket / reason / approved_by / expires"
          " de viec noi long hien ra trong diff cua PR")
        continue

    for f in ("ticket", "reason", "approved_by", "expires"):
        if not lo.get(f):
            E(f"{pol}/{sid}: khoi `loosen` thieu `{f}`")

    exp = str(lo.get("expires") or "")
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", exp):
        d = datetime.date.fromisoformat(exp)
        con = (d - hom_nay).days
        if con < 0:
            m = (f"{pol}/{sid}: khoi `loosen` HET HAN {-con} ngay"
                 f" ({exp}, ticket {lo.get('ticket')})")
            (E if MODE_EXP else W)(m)
        elif con <= 30:
            W(f"{pol}/{sid}: `loosen` het han sau {con} ngay ({exp})")
    elif exp:
        E(f"{pol}/{sid}: `expires` phai dang YYYY-MM-DD, dang: {exp}")

########################################
# BAO CAO
########################################
n_stmt = len(flat)
n_locked = sum(1 for _, s in flat if s.get("locked"))
n_loosen = sum(1 for _, s in flat if s.get("loosen"))
n_scope  = sum(1 for _, s in flat if s.get("pipeline_scope"))

print()
print(f"  Catalog: {len(POLICIES)} policy, {n_stmt} statement"
      f"  ({n_locked} locked, {n_loosen} co khoi loosen,"
      f" {n_scope} da xem xet pham vi pipeline)")

if AWS_DUMP:
    that = n_stmt - len(noi_long)
    print(f"  Doi chieu AWS: {len(noi_long)} thay doi NOI"
          f" / {that} con lai la THAT hoac khong doi")
else:
    print(f"  {Y}BO QUA phep phan biet THAT/NOI{N} - can ./lint.sh --aws."
          "\n    Day KHONG phai 'khong co gi noi long', la CHUA SO.")

for m in canh:
    print(f"  {Y}CANH BAO{N}  {m}")
for m in loi:
    print(f"  {R}LOI{N}       {m}")

print()
if loi:
    print(f"  {R}{len(loi)} loi{N}, {len(canh)} canh bao.")
    sys.exit(1)
if canh and STRICT:
    print(f"  {Y}{len(canh)} canh bao{N}, --strict nen coi la loi.")
    sys.exit(1)
print(f"  {G}Sach.{N} {len(canh)} canh bao.")
print("\n  Buoc tiep: terraform plan")
PY
