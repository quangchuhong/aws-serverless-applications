#!/usr/bin/env bash
#
# Kiem catalog TRUOC KHI cham vao Terraform.
#
# KHONG can AWS credential, KHONG can terraform init, KHONG goi mang.
# Chay het trong duoi mot giay, nen chay duoc o moi commit va o moi
# lan luu file.
#
# VI SAO CAN, KHI TERRAFORM DA CO PRECONDITION
#
# Precondition bat gan het nhung thu o day - nhung chi khi ai do co
# state, co credential, va chiu doi `terraform init` + `plan`. Nguoi
# mo PR de them mot dong YAML thuong khong co ca ba. Neu vong phan hoi
# ngan nhat cua ho la "doi CI 4 phut", ho se doan thay vi kiem.
#
# Va co ba thu Terraform KHONG bat duoc, deu quan trong:
#
#   1. Rule TRUNG NOI DUNG duoi hai id khac nhau. Ca hai deu hop le,
#      ca hai deu apply, chung khong xung dot. Chung chi lam danh sach
#      dai them va lam nguoi doc tin rang co hai ly do de mo mot
#      luong - nen khi mot ticket dong, khong ai dam go dong nao.
#
#   2. Rule sap het han. Precondition chi biet DA het han hay chua;
#      canh bao truoc 30 ngay la viec cua cai chay theo lich.
#
#   3. YAML sai cu phap. Terraform bao loi tu yamldecode voi mot
#      thong bao khong noi dong nao.
#
# Ma thoat: 0 = sach. 1 = co loi. Canh bao khong lam thoat khac 0 tru
# khi chay voi --strict (CI dung --strict).

set -uo pipefail

cd "$(dirname "$0")" || exit 1

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

CATALOG="${CATALOG_DIR:-catalog}"

########################################
# STATE CUA LAYER CHA
#
# Kiem TRUOC catalog, vi thieu no thi khong mot phep kiem nao ben duoi
# co nghia: ten spoke, bang route, ten zone - tat ca deu doc tu do.
#
# Terraform bao truong hop nay bang:
#
#   Error: Unable to find remote state
#   No stored state was found for the given workspace in the given backend.
#
# Cau do khong in ra duong dan da thu, va doc y het nhu "layer cha
# chua bao gio duoc apply". Hai nguyen nhan that su khac han nhau:
# hoac chua apply, hoac apply roi nhung chua co output ops_handles.
# Phan biet o day.
#
# Chi ap dung cho backend local. Voi S3 thi khong kiem duoc ma khong
# goi mang, va script nay co y khong goi mang.
########################################

HUB_STATE="${HUB_STATE:-../terraform.tfstate}"

# Doc state_backend TU terraform.tfvars, khong chi tu bien moi truong.
#
# Truoc day dong nay chi xem bien moi truong, nen ai khai
# state_backend = "s3" trong tfvars van bi phep kiem local chan lai -
# script tu bao mot loi ma chinh cau hinh cua nguoi dung da giai quyet.
TFVARS_BACKEND=""
if [[ -f terraform.tfvars ]]; then
  TFVARS_BACKEND=$(grep -E '^[[:space:]]*state_backend[[:space:]]*=' terraform.tfvars 2>/dev/null |
    head -1 | sed -E 's/.*=[[:space:]]*"([a-z0-9]+)".*/\1/')
fi

BACKEND_MODE="${STATE_BACKEND:-${TFVARS_BACKEND:-local}}"

if [[ "${SKIP_STATE_CHECK:-0}" != "1" && "$BACKEND_MODE" == "local" ]]; then
  if [[ ! -s "$HUB_STATE" ]]; then
    echo
    echo "  Khong tim thay state cua layer cha."
    echo "    Da thu: $(cd .. 2>/dev/null && pwd)/terraform.tfstate"
    echo

    ########################################
    # DI TIM THAY VI BAO NGUOI DUNG DI TIM
    #
    # "Khong thay file X" la mot cau tra loi dung nhung vo dung: no
    # bat nguoi doc lam lai chinh phep tim ma script vua lam. Bon
    # nguyen nhan duoi day chiem gan het cac truong hop, va ca bon
    # deu tra loi duoc ma khong can hoi ai.
    ########################################

    # 1. Layer cha khai backend tu xa -> state khong nam tren dia
    #
    # Khong dung lai o cho bao "co backend": cau hinh that nam san
    # trong ../.terraform/terraform.tfstate - file Terraform ghi luc
    # init de nho no dang tro di dau. Doc thang tu do thi khoi phai
    # ai go lai bucket/key/region bang tay, va khoi go sai.
    BACKEND_TYPE=$(grep -rhoE 'backend[[:space:]]+"[a-z0-9]+"' ../*.tf 2>/dev/null |
      head -1 | sed -E 's/.*"([a-z0-9]+)"/\1/')

    if [[ -n "$BACKEND_TYPE" ]]; then
      echo "  Layer cha khai backend \"$BACKEND_TYPE\" - state KHONG nam tren dia."
      echo

      CACHE="../.terraform/terraform.tfstate"
      CFG=""
      if [[ -s "$CACHE" ]] && command -v jq >/dev/null 2>&1; then
        # Chi lay gia tri chuoi: bien state_config la map(string), nen
        # mot dong bool nhu `encrypt = true` se lam terraform tu choi.
        # Nhung khoa can de DOC state deu la chuoi (bucket, key,
        # region, profile, role_arn, kms_key_id).
        #
        # Bo dynamodb_table: terraform_remote_state chi DOC, khong bao
        # gio khoa. Giu lai thi Terraform in canh bao deprecated moi
        # lan plan - mot dong nhieu vo ich cho mot thu khong dung toi.
        CFG=$(jq -r '
          .backend.config // {}
          | to_entries[]
          | select(.value != null and (.value | type) == "string")
          | select(.key != "dynamodb_table")
          | "      \(.key) = \"\(.value)\""
        ' "$CACHE" 2>/dev/null)
      fi

      if [[ -n "$CFG" ]]; then
        echo "  Cau hinh that, doc tu $CACHE - dan vao ops/terraform.tfvars:"
        echo
        echo "    state_backend = \"$BACKEND_TYPE\""
        echo "    state_config = {"
        echo "$CFG"
        echo "    }"
        echo
        # KHONG can init lai. state_config chi dieu khien
        # terraform_remote_state - mot DATA SOURCE. Backend cua chinh
        # lop nay la chuyen khac, nam o backend.tf. Bao "init
        # -reconfigure" o day la chi nguoi ta di lam mot viec khong
        # lien quan, roi ho quay lai voi dung loi cu.
        echo "  Roi chay lai: ./lint.sh && terraform plan"
      else
        echo "  Chua doc duoc cau hinh (thieu $CACHE hoac thieu jq)."
        echo "  Xem truc tiep:"
        echo
        echo "    grep -A8 'backend \"$BACKEND_TYPE\"' ../*.tf"
        echo
        echo "  Roi khai lai o ops/terraform.tfvars cho khop:"
        echo "    state_backend = \"$BACKEND_TYPE\""
        echo "    state_config  = { bucket = \"...\", key = \"...\", region = \"...\" }"
      fi

      echo
      # Chi nhac khi lop nay THAT SU con dung state local. Sau khi
      # wire-backends.sh chay thi backend.tf da co, va nhac nua la sai.
      if [[ ! -f backend.tf ]]; then
        echo "  LUU Y: state cua CHINH lop ops van dang ghi ra dia. Layer cha"
        echo "  dung backend tu xa thi lop nay nen theo. Dang ky no nhu mot"
        echo "  layer trong landing-zone/tf-backend - xem versions.tf."
        echo
      fi
      exit 1
    fi

    # 2. Workspace khac "default"
    if [[ -d "../terraform.tfstate.d" ]]; then
      echo "  Co ../terraform.tfstate.d/ - layer cha dang dung WORKSPACE:"
      for w in ../terraform.tfstate.d/*/; do
        [[ -s "$w/terraform.tfstate" ]] && echo "    $(basename "$w")"
      done
      echo
      echo "  terraform_remote_state doc workspace 'default'. Tro thang toi file:"
      echo "    state_config = { path = \"$(cd .. && pwd)/terraform.tfstate.d/<ten>/terraform.tfstate\" }"
      echo
      exit 1
    fi

    # 3. State nam o cho khac trong repo - tim that
    ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "..")
    FOUND=$(find "$ROOT" -maxdepth 4 -name 'terraform.tfstate' -size +1c \
      -not -path '*/.terraform/*' 2>/dev/null | head -10)

    if [[ -n "$FOUND" ]]; then
      echo "  Tim thay state o cho khac trong repo:"
      echo
      while IFS= read -r f; do
        # In kem ID account de biet cai nao la layer network
        acct=""
        command -v jq >/dev/null 2>&1 && acct=$(jq -r '.outputs.account_id.value // ""' "$f" 2>/dev/null)
        [[ -n "$acct" ]] && echo "    $f   (account $acct)" || echo "    $f"
      done <<< "$FOUND"
      echo
      echo "  Tro toi cai dung bang duong dan TUYET DOI:"
      echo "    state_config = { path = \"<duong dan o tren>\" }"
      echo
      exit 1
    fi

    # 4. Khong co gi ca
    echo "  Khong tim thay file terraform.tfstate nao trong repo."
    echo
    echo "  Nghia la thu muc da apply layer cha KHONG PHAI thu muc cha cua"
    echo "  thu muc nay - rat co the ban chay demo tu mot ban sao khac."
    echo "  Tim tren ca may:"
    echo
    echo "    find ~ -name terraform.tfstate -path '*network-lz-full*' 2>/dev/null"
    echo
    echo "  Roi tro toi no:"
    echo "    state_config = { path = \"/duong/dan/tuyet/doi/terraform.tfstate\" }"
    echo
    echo "  Bo qua phep kiem nay: SKIP_STATE_CHECK=1 ./lint.sh"
    echo
    exit 1
  fi

  if command -v jq >/dev/null 2>&1; then
    if [[ "$(jq -r '.outputs.ops_handles // "thieu"' "$HUB_STATE")" == "thieu" ]]; then
      echo
      echo "  State cua layer cha co, nhung CHUA co output \"ops_handles\"."
      echo
      echo "  Nghia la layer cha chua duoc apply lai sau khi keo code moi ve."
      echo "  Chi them mot output, khong doi resource nao:"
      echo
      echo "    cd .. && terraform apply     # 0 to add, 0 to change"
      echo
      echo "  Bo qua buoc nay thi terraform ben duoi se bao:"
      echo "    This object does not have an attribute named \"ops_handles\""
      echo "  - mot cau khong he nhac toi viec phai apply layer cha."
      echo
      exit 1
    fi
  fi
fi

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "Thieu module PyYAML. Cai bang:"
  echo "  python3 -m pip install --user pyyaml"
  echo
  echo "(Neu khong muon cai: terraform plan van kiem gan het nhung thu"
  echo " nay qua precondition, chi cham hon va can credential.)"
  exit 1
fi

CATALOG_DIR="$CATALOG" STRICT="$STRICT" python3 - <<'PY'
import os, re, sys, ipaddress, datetime

try:
    import yaml
except ImportError:
    sys.exit("PyYAML chua duoc cai")

D = os.environ["CATALOG_DIR"]
STRICT = os.environ["STRICT"] == "1"

errors, warns = [], []
def err(f, m):  errors.append(f"{f}: {m}")
def warn(f, m): warns.append(f"{f}: {m}")

def load(name, key):
    p = os.path.join(D, name)
    if not os.path.exists(p):
        err(name, "khong tim thay file")
        return []
    try:
        doc = yaml.safe_load(open(p, encoding="utf-8"))
    except yaml.YAMLError as e:
        # Thong bao cua PyYAML co so dong - thu Terraform khong co.
        err(name, f"YAML sai cu phap:\n    {str(e).replace(chr(10), chr(10) + '    ')}")
        return []
    if doc is None:
        return []
    if not isinstance(doc, dict) or key not in doc:
        err(name, f"phai co khoa '{key}' o muc cao nhat")
        return []
    v = doc[key]
    if v is None:
        return []
    if not isinstance(v, list):
        err(name, f"'{key}' phai la mot danh sach")
        return []
    return v

def is_cidr(s):
    try:
        ipaddress.ip_network(str(s), strict=False)
        return True
    except Exception:
        return False

def inside(sub, parent):
    try:
        return ipaddress.ip_network(str(sub), strict=False).subnet_of(
            ipaddress.ip_network(str(parent), strict=False))
    except Exception:
        return False

apps_raw = load("apps.yaml", "apps")
fw_raw   = load("firewall-rules.yaml", "rules")
rt_raw   = load("routes.yaml", "routes")
ep_raw   = load("endpoints.yaml", "endpoints")
dns_raw  = load("dns-records.yaml", "records")
ptn_raw  = load("partners.yaml", "partners")

# Moc thoi gian dung chung cho partners.yaml va firewall-rules.yaml.
# Khai o day vi khoi partner chay TRUOC khoi rule.
today = datetime.date.today()
soon = today + datetime.timedelta(days=30)

########################################
# partners.yaml
#
# Kiem TRUOC apps.yaml: moi doi tac sinh ra mot ten "partner-<name>"
# dung duoc trong firewall-rules.yaml, nen bang apps phai co chung
# truoc khi kiem rule.
########################################
F = "partners.yaml"
partners = {}
services = []   # (khoa, doi tac, ten dich vu, khoi dich vu, khoi doi tac)
for i, p in enumerate(ptn_raw):
    if not isinstance(p, dict):
        err(F, f"muc thu {i+1} khong phai mot khoi khoa/gia tri"); continue
    n = p.get("name")
    if not n:
        err(F, f"muc thu {i+1} thieu 'name'"); continue
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", str(n)):
        err(F, f"ten khong hop le: {n!r} - chi chu thuong, so va gach ngang "
               "(ten nay ghep thanh 'partner-<name>')")
    if n in partners:
        err(F, f"ten doi tac trung: {n}")
    if not p.get("remote_cidr"):
        err(F, f"{n}: thieu 'remote_cidr' - dai doi tac cong bo cho ban")
    elif not is_cidr(p["remote_cidr"]):
        err(F, f"{n}: remote_cidr khong hop le: {p['remote_cidr']}")
    if not p.get("contact"):
        warn(F, f"{n}: chua khai 'contact' - luc duong ham dut thi khong biet goi ai")
    if not p.get("ticket"):
        warn(F, f"{n}: chua khai 'ticket' - ket noi doi tac khong co hop dong ghi lai thi khong ai dam cat")

    exp = p.get("expires")
    if exp is not None:
        try:
            d = exp if isinstance(exp, datetime.date) else datetime.date.fromisoformat(str(exp))
        except Exception:
            err(F, f"{n}: expires phai la YYYY-MM-DD, dang co {exp!r}"); d = None
        if d:
            if d < today:
                err(F, f"{n}: HOP DONG DA HET HAN {d} - gia han, hoac go doi tac va cac rule cua ho")
            elif d <= soon:
                warn(F, f"{n}: hop dong het han {d} (con {(d-today).days} ngay)")
    else:
        warn(F, f"{n}: khong co 'expires' - ket noi doi tac vinh vien la thu khong ai ra soat lai bao gio")

    if p.get("extra_cidrs"):
        if not isinstance(p["extra_cidrs"], list):
            err(F, f"{n}: 'extra_cidrs' phai la mot danh sach")
        else:
            for c in p["extra_cidrs"]:
                if not is_cidr(c):
                    err(F, f"{n}: extra_cidrs co dai khong hop le: {c}")
                elif c == p.get("remote_cidr"):
                    err(F, f"{n}: extra_cidrs lap lai remote_cidr ({c}) - "
                           "layer cha da so huu route do, khai lai thi AWS tu choi "
                           "o GIUA apply bang mot ma loi khong noi gi ve layer cha")

    for j, s in enumerate(p.get("services", []) or []):
        if not isinstance(s, dict):
            err(F, f"{n}: dich vu thu {j+1} khong phai mot khoi khoa/gia tri"); continue
        sn = s.get("name")
        if not sn:
            err(F, f"{n}: dich vu thu {j+1} thieu 'name'"); continue
        key = f"{n}-{sn}"
        # Ten target group = "<project>-p-<key>", AWS gioi han 32 ky tu.
        # Khong biet project o day nen chua mot khoang du rong.
        if len(key) > 20:
            err(F, f"{key}: ten qua dai ({len(key)} ky tu). Ten target group ghep tu "
                   "'<project>-p-<doi tac>-<dich vu>' va AWS gioi han 32 ky tu")
        services.append((key, n, sn, s, p))

    partners[n] = p

########################################
# apps.yaml
########################################
F = "apps.yaml"
apps = {}
# Doi tac tro thanh app dung duoc trong firewall-rules.yaml.
# spoke = None vi chung khong thuoc spoke nao - kiem "cung spoke" ben
# duoi bo qua chung.
for n in partners:
    apps[f"partner-{n}"] = {"name": f"partner-{n}", "spoke": None, "partner": True}
seen = set()
for i, a in enumerate(apps_raw):
    if not isinstance(a, dict):
        err(F, f"muc thu {i+1} khong phai mot khoi khoa/gia tri"); continue
    n = a.get("name")
    if not n:
        err(F, f"muc thu {i+1} thieu 'name'"); continue
    if n in seen:
        err(F, f"ten trung: {n}")
    seen.add(n)
    if not a.get("spoke"):
        err(F, f"{n}: thieu 'spoke'")
    if "cidr" in a and a["cidr"] is not None and not is_cidr(a["cidr"]):
        err(F, f"{n}: cidr khong hop le: {a['cidr']}")
    if not a.get("owner"):
        warn(F, f"{n}: chua khai 'owner' - mot nam nua se khong biet hoi ai")
    apps[n] = a

########################################
# DICH VU CONG BO CHO DOI TAC
#
# Chay SAU apps.yaml: target duoc khai bang TEN APP, nen phai co bang
# apps roi moi giai duoc.
#
# Cong la tai nguyen dung chung: MOT NLB cho moi doi tac, va NLB chi
# cho MOT listener tren mot cong. Nen hai doi tac khac nhau van cham
# cong nhau duoc - do la thu kiem o day, va la thu khong ai ngo khi
# chi doc ho so cua rieng mot doi tac.
########################################
F = "partners.yaml"
port_owner = {}
for key, pn, sn, s, p in services:
    port = s.get("port")
    try:
        port = int(port)
        if not (1 <= port <= 65535): raise ValueError
    except Exception:
        err(F, f"{key}: 'port' khong hop le: {s.get('port')!r}"); port = None

    if port is not None:
        if port in port_owner:
            err(F, f"{key}: trung cong {port} voi {port_owner[port]}. Mot NLB chi cho "
                   "MOT listener tren mot cong, ke ca khi hai dich vu thuoc hai doi tac "
                   "khac nhau - vi ca hai di chung mot NLB")
        else:
            port_owner[port] = key

    tp = s.get("target_port", s.get("port"))
    try:
        tp = int(tp)
        if not (1 <= tp <= 65535): raise ValueError
    except Exception:
        err(F, f"{key}: 'target_port' khong hop le: {s.get('target_port')!r}"); tp = None

    # Cong ngoai khac cong trong la binh thuong. Nhac mot lan de nguoi
    # viet rule firewall biet phai mo cong NAO - day la cho de nham
    # nhat trong ca file, vi ho vua go cong kia cach do ba dong.
    if tp is not None and port is not None and tp != port:
        warn(F, f"{key}: doi tac goi cong {port}, ung dung nghe cong {tp}. "
                f"Rule firewall phai mo cong {tp} - firewall nhin thay ket noi "
                "THU HAI, tu NLB toi ung dung, khong phai ket noi cua doi tac")

    tip, tgt = s.get("target_ip"), s.get("target")
    if tip:
        if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", str(tip)):
            err(F, f"{key}: target_ip phai la MOT dia chi, dang co {tip!r}")
    elif not tgt:
        err(F, f"{key}: thieu 'target' (ten app trong apps.yaml) hoac 'target_ip'")
    elif tgt not in apps:
        err(F, f"{key}: target={tgt} khong co trong apps.yaml")
    elif apps[tgt].get("partner"):
        err(F, f"{key}: target={tgt} la mot DOI TAC, khong phai ung dung. "
               "NLB se tro ve chinh dai NLB - mot vong lap")
    elif not str(apps[tgt].get("cidr", "")).endswith("/32"):
        err(F, f"{key}: target={tgt} giai ra mot DAI, khong phai mot dia chi. "
               "NLB can dung mot dia chi. Cach sua: trong apps.yaml khai "
               f"cidr dang 10.x.x.x/32 cho {tgt}, hoac khai target_ip thang o day")

    if not s.get("ticket") and not p.get("ticket"):
        warn(F, f"{key}: chua khai 'ticket' - mot cua mo cho ben ngoai ma khong "
                "co gi ghi lai ai duyet")

    exp = s.get("expires", p.get("expires"))
    if exp is not None:
        try:
            d = exp if isinstance(exp, datetime.date) else datetime.date.fromisoformat(str(exp))
        except Exception:
            err(F, f"{key}: expires phai la YYYY-MM-DD, dang co {exp!r}"); d = None
        if d:
            if d < today:
                err(F, f"{key}: DICH VU DA HET HAN {d} - con listener nghia la doi tac "
                       "VAN GOI DUOC. Het han o day khong tu dong dong cua")
            elif d <= soon:
                warn(F, f"{key}: dich vu het han {d} (con {(d-today).days} ngay)")

# KHONG kiem alarm_actions o day.
#
# lint.sh doc CATALOG. alarm_actions la mot bien Terraform - no khong
# nam trong file YAML nao, nen lint khong the biet no da duoc dat hay
# chua. Mot canh bao khong the tat duoc bang cach sua dung thu no noi
# la mot canh bao se do mai trong CI, va sau vai lan thi khong ai doc
# ca dong canh bao nua.
#
# Phep kiem do nam o check "partner_alarms_reach_someone" trong
# vpn.tf, la cho DUY NHAT nhin thay ca hai thu cung luc.

########################################
# firewall-rules.yaml
########################################
F = "firewall-rules.yaml"
ids, content_seen = set(), {}
n_ports_total = 0

for i, r in enumerate(fw_raw):
    if not isinstance(r, dict):
        err(F, f"muc thu {i+1} khong phai mot khoi khoa/gia tri"); continue
    rid = r.get("id", "")
    # KHONG dung lai o day. Bao id sai roi bo qua ca khoi nghia la
    # nguoi sua phai chay lai lint de thay cac loi con lai - moi vong
    # mot loi. Kiem het roi in mot lan.
    if not re.fullmatch(r"fw-[0-8][0-9]{3}", str(rid)) or rid == "fw-0000":
        err(F, f"id sai dinh dang: {rid!r} - phai la fw-NNNN, 0001..8999")
    if rid in ids:
        err(F, f"id trung: {rid} - hai rule cung sid thi Suricata nap cai dau va BO IM LANG cai sau")
    ids.add(rid)

    proto = str(r.get("protocol", "tcp")).lower()
    if proto not in ("tcp", "udp", "icmp"):
        err(F, f"{rid}: protocol khong ho tro: {proto}")

    for side in ("from", "to"):
        who = r.get(side)
        if not who:
            err(F, f"{rid}: thieu '{side}'")
        elif who not in apps:
            err(F, f"{rid}: {side}={who} khong co trong apps.yaml")

    ports = r.get("ports", []) or []
    if proto == "icmp":
        if ports:
            err(F, f"{rid}: protocol icmp thi khong khai 'ports'")
        # Layer cha da cho qua moi luong icmp noi bo o uu tien 100.
        warn(F, f"{rid}: rule icmp khong bao gio duoc doc toi - "
                "../firewall.tf da co 'pass icmp' (sid 1900) o rule group uu tien 100, "
                "va o STRICT_ORDER thi pass ket thuc danh gia")
    else:
        if not ports:
            err(F, f"{rid}: thieu 'ports'")
        for p in ports:
            try:
                p = int(p)
                if not (1 <= p <= 65535): raise ValueError
            except Exception:
                err(F, f"{rid}: port khong hop le: {p!r}")
        n_ports_total += max(1, len(ports))

    if not r.get("ticket"):
        warn(F, f"{rid}: chua khai 'ticket' - dai rule chi dai them chu khong ngan lai bao gio")

    exp = r.get("expires")
    if exp is not None:
        try:
            d = exp if isinstance(exp, datetime.date) else datetime.date.fromisoformat(str(exp))
        except Exception:
            err(F, f"{rid}: expires phai la YYYY-MM-DD, dang co {exp!r}")
            d = None
        if d:
            if d < today:
                err(F, f"{rid}: DA QUA HAN {d} - go rule di, hoac gia han ticket")
            elif d <= soon:
                warn(F, f"{rid}: het han {d} (con {(d-today).days} ngay)")

    # Trung NOI DUNG duoi hai id khac nhau.
    #
    # Terraform khong bat duoc: ca hai deu hop le va khong xung dot.
    # Hau qua khong phai loi ky thuat ma la loi CON NGUOI - danh sach
    # dai them, va khi mot ticket dong thi khong ai dam go dong nao vi
    # khong ro dong kia con dung khong.
    key = (r.get("from"), r.get("to"), proto, tuple(sorted(str(p) for p in ports)))
    if key in content_seen:
        warn(F, f"{rid} trung noi dung voi {content_seen[key]} "
                f"({r.get('from')} -> {r.get('to')} {proto} {ports})")
    else:
        content_seen[key] = rid

    # Rule tro TOI mot doi tac la sai chieu.
    #
    # "partner-x" giai ra dai NLB trong vung dem - do la NGUON cua
    # luu luong doi tac gui vao, sau khi NLB mo ket noi moi. No khong
    # bao gio la DICH.
    #
    # Chieu ban goi doi tac di qua private NAT toi dai that cua ho
    # (172.16.x), khong qua NLB. Khai "to: partner-x" se apply thanh
    # cong va khong khop mot goi tin nao.
    ta_name = r.get("to")
    if ta_name and apps.get(ta_name, {}).get("partner"):
        err(F, f"{rid}: to={ta_name} - dai NLB la NGUON cua luu luong doi tac, "
               "khong phai dich. Chieu ban goi doi tac di qua private NAT toi dai "
               "that cua ho, khong qua NLB.")

    # from == to: luong trong cung mot VPC khong di qua TGW nen khong
    # bao gio toi firewall. Rule apply xong va khong khop gi.
    fa, ta = apps.get(r.get("from")), apps.get(r.get("to"))
    if fa and ta and fa.get("spoke") is not None \
       and fa.get("spoke") == ta.get("spoke") \
       and fa.get("cidr") is None and ta.get("cidr") is None:
        err(F, f"{rid}: from va to cung mot spoke ({fa.get('spoke')}). "
               "Luu luong trong cung VPC khong qua TGW nen khong toi firewall - "
               "do la viec cua security group.")

########################################
# routes.yaml
########################################
F = "routes.yaml"
TABLES = {"spokes", "security", "egress", "ingress"}
rt_ids = set()
for i, r in enumerate(rt_raw):
    if not isinstance(r, dict):
        err(F, f"muc thu {i+1} khong phai mot khoi khoa/gia tri"); continue
    rid = r.get("id", "")
    if not re.fullmatch(r"rt-[0-9]{4}", str(rid)):
        err(F, f"id sai dinh dang: {rid!r} - phai la rt-NNNN")
    if rid in rt_ids:
        err(F, f"id trung: {rid}")
    rt_ids.add(rid)

    if r.get("table") not in TABLES:
        err(F, f"{rid}: table={r.get('table')!r} - phai la mot trong {sorted(TABLES)}")
    if not is_cidr(r.get("destination")):
        err(F, f"{rid}: destination khong hop le: {r.get('destination')!r}")

    t = str(r.get("target", ""))
    ok = (t == "blackhole"
          or t.startswith("spoke:")
          or t in ("hub:egress", "hub:security", "hub:ingress")
          or re.fullmatch(r"attachment:tgw-attach-[0-9a-f]+", t))
    if not ok:
        err(F, f"{rid}: target khong hop le: {t!r} - "
               "dang cho phep: blackhole | spoke:<ten> | hub:<egress|security|ingress> | attachment:tgw-attach-...")

    if not r.get("ticket"):
        warn(F, f"{rid}: chua khai 'ticket'")

    # Route ngoai le la thu kho doan nhat trong ca bo. Khong co mot
    # cau tieng nguoi giai thich thi nguoi ke tiep chi co hai lua chon
    # deu xau: giu mai, hoac go va cho xem co gi hong.
    if not r.get("note"):
        warn(F, f"{rid}: chua khai 'note' - route ngoai le khong co ly do ghi lai thi khong ai dam go")

########################################
# endpoints.yaml
########################################
F = "endpoints.yaml"
# Bo layer cha giu - dong bo voi interface_endpoint_services
PARENT_EP = {"ssm", "ssmmessages", "ec2messages"}
ep_seen = set()
for i, e in enumerate(ep_raw):
    if not isinstance(e, dict):
        err(F, f"muc thu {i+1} khong phai mot khoi khoa/gia tri"); continue
    s = e.get("service")
    if not s:
        err(F, f"muc thu {i+1} thieu 'service'"); continue
    if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,60}", str(s)):
        err(F, f"ten dich vu khong hop le: {s!r} - dung ten NGAN (kms), "
               "Terraform tu ghep thanh com.amazonaws.<region>.<service>")
    if s in ep_seen:
        err(F, f"dich vu trung: {s}")
    ep_seen.add(s)
    if s in PARENT_EP:
        err(F, f"{s}: LAYER CHA da tao dich vu nay. Tao them la hai bo ENI, "
               "hai hoa don, va hai PHZ cung ten che nhau.")
    if str(s).startswith(("ecr.", "elasticfilesystem")) and not e.get("wildcard"):
        warn(F, f"{s}: dich vu nay co ten nam o TIEN TO - can wildcard: true. "
                "Thieu no thi mot nua so loi goi di ra Internet con nua kia thi khong.")
    if not e.get("ticket"):
        warn(F, f"{s}: chua khai 'ticket' - ~$0.01/gio moi AZ, khong ai nho da bat cho ai thi khong ai dam tat")

########################################
# dns-records.yaml
########################################
F = "dns-records.yaml"
TYPES = {"A", "AAAA", "CNAME", "TXT", "SRV"}
dns_seen = set()
for i, r in enumerate(dns_raw):
    if not isinstance(r, dict):
        err(F, f"muc thu {i+1} khong phai mot khoi khoa/gia tri"); continue
    n = r.get("name")
    if not n:
        err(F, f"muc thu {i+1} thieu 'name'"); continue
    if n in dns_seen:
        err(F, f"ten trung: {n}")
    dns_seen.add(n)
    if "." in str(n) and n != "@":
        warn(F, f"{n}: 'name' nen la ten NGAN, khong gom ten mien - "
                "Terraform tu ghep zone vao. Khai ca ten mien se ra "
                f"'{n}.<zone>'.")

    t = str(r.get("type", "A")).upper()
    if t not in TYPES:
        err(F, f"{n}: kieu khong ho tro: {t}")

    vals = r.get("values") or []
    if not vals:
        err(F, f"{n}: thieu 'values' - ban ghi rong khong phai la xoa, no la mot loi API")
    if t == "A":
        for v in vals:
            try:
                ipaddress.IPv4Address(str(v))
            except Exception:
                err(F, f"{n}: gia tri khong phai IPv4: {v!r}")

    ttl = r.get("ttl", 60)
    try:
        ttl = int(ttl)
        if not (30 <= ttl <= 86400): raise ValueError
    except Exception:
        err(F, f"{n}: ttl={r.get('ttl')!r} - dung trong khoang 30..86400")

    if not r.get("ticket"):
        warn(F, f"{n}: chua khai 'ticket' - ten trong PHZ tap trung hien ra o MOI account")

########################################
# Ket qua
########################################
print()
print("  Catalog: %d app, %d rule firewall, %d route, %d endpoint, %d ban ghi DNS, %d doi tac"
      % (len(apps), len(ids), len(rt_ids), len(ep_seen), len(dns_seen), len(partners)))
if services:
    print("  Dich vu cong bo cho doi tac: %d" % len(services))
# Network Firewall tinh capacity theo so to hop nguon x dich x port.
# Rule cua ta luon 1 nguon x 1 dich, nen chi phi la so port. +10% du.
print("  Capacity uoc tinh: ~%d (mac dinh rule group: 1000)" % (int(n_ports_total * 1.1) + 1))
print()

for w in warns:
    print(f"  CANH BAO  {w}")
if warns:
    print()
for e in errors:
    print(f"  LOI       {e}")
if errors:
    print()

if errors:
    print("  %d loi, %d canh bao - SUA TRUOC KHI APPLY" % (len(errors), len(warns)))
    sys.exit(1)
if warns and STRICT:
    print("  0 loi, %d canh bao - --strict nen coi la that bai" % len(warns))
    sys.exit(1)
print("  Sach. %d canh bao." % len(warns))
print()
print("  Buoc tiep: terraform plan   (kiem them nhung thu can doc state cua layer cha:")
print("             ten spoke co that khong, route co dam vao layer cha khong,")
print("             ban ghi DNS co trung ten layer cha sinh ra khong)")
PY

exit $?
