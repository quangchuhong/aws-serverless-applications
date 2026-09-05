#!/usr/bin/env bash
#
# Kiem yeu cau tao account TRUOC khi plan.
#
# KHONG can AWS, khong can terraform init, khong can mang. Vai giay.
#
# ---------------------------------------------------------------
# VI SAO LOP NAY CAN LINT HON MOI LOP KHAC
#
# Rule firewall go nham thi sua bang mot commit. Account go nham thi
# khong sua duoc:
#
#   - email sai mot ky tu -> account do ton tai vinh vien voi email
#     do, va email dung thi khong ai dung duoc nua
#   - ou sai            -> account chi con SCP o root, mat
#                          network_lock va prod_guard, van chay
#                          binh thuong
#   - vpc_cidr trung    -> hai spoke trung dai trong mot luoi TGW.
#                          Route table khong phan biet duoc, va sua
#                          thi phai xoa VPC
#
# Ba thu tren deu KHONG bao loi luc apply. Do la ly do file nay ton
# tai, va la ly do no chan chu khong canh bao.
# ---------------------------------------------------------------

set -uo pipefail
cd "$(dirname "$0")"

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

python3 - "$STRICT" <<'PY'
import sys, os, re, ipaddress

try:
    import yaml
except ImportError:
    print("  Thieu pyyaml:  python3 -m pip install pyyaml")
    sys.exit(2)

strict = sys.argv[1] == "1"
errors, warns = [], []


def err(msg):
    errors.append(msg)


def warn(msg):
    warns.append(msg)


PATH = "catalog/accounts.yaml"
if not os.path.exists(PATH):
    print(f"  Khong tim thay {PATH}")
    sys.exit(2)

try:
    doc = yaml.safe_load(open(PATH, encoding="utf-8")) or {}
except yaml.YAMLError as e:
    print(f"  {PATH} khong phai YAML hop le:\n    {e}")
    sys.exit(2)

raw = doc.get("accounts") or []
if not isinstance(raw, list):
    print(f"  {PATH}: 'accounts' phai la mot danh sach")
    sys.exit(2)

# Danh sach OU hop le. Doi chieu voi cay OU o doc 06 muc 3.
#
# Giu o day chu khong doc tu AWS: lint phai chay duoc offline, va mot
# ten OU go nham can bi chan TRUOC khi ai do co credential.
OUS = {
    "Infrastructure", "Security", "Workloads", "NonProd", "Prod",
    "Analytics", "Sandbox", "Suspended", "Root",
}
SCOPES = {"analytics", "nonprod", "prod", "none"}
ENVS = {"dev", "staging", "prod", "sandbox"}

# Dai cap phat theo doc 17 muc 3, viet thanh KHOANG octet thu hai
# chu khong phai CIDR.
#
# Ly do khong phai tham my: "10.10.0.0/14" KHONG PHAI mot CIDR hop le.
# Mot /14 bat dau o boi so cua 4, nen no chi co the la 10.8.0.0/14
# (phu 10.8-10.11) hoac 10.12.0.0/14 (10.12-10.15). Khoang 10.10-10.13
# ma bang cap phat mo ta khong viet duoc thanh MOT /14 nao.
#
# Bang goc ghi ca hai: "10.10.0.0/14 (10.10 - 10.13)". Phan trong
# ngoac la y dinh that; phan CIDR la mot phep tinh sai chua ai chay.
# Giu KHOANG - do la thu con nguoi thoa thuan voi nhau - va bo cach
# viet CIDR di.
ALLOCATED = {
    "NonProd": (10, 13),
    "Prod": (20, 23),
    "Analytics": (30, 33),
    "Sandbox": (60, 63),
}

# Dai HA TANG - khong bao gio cap cho workload.
RESERVED = [
    (ipaddress.ip_network("10.0.0.0/16"), "ingress VPC"),
    (ipaddress.ip_network("10.1.0.0/16"), "security VPC"),
    (ipaddress.ip_network("10.2.0.0/16"), "egress VPC"),
    (ipaddress.ip_network("10.9.0.0/16"), "3rd-party VPC (doi tac)"),
]

seen_names, seen_emails, nets = {}, {}, []

for i, a in enumerate(raw):
    if not isinstance(a, dict):
        err(f"muc thu {i+1} khong phai mot khoi khoa/gia tri")
        continue

    n = a.get("name")
    if not n:
        err(f"muc thu {i+1} thieu 'name'")
        continue
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,58}[a-z0-9]", str(n)):
        err(f"{n}: ten khong hop le - chu thuong, so, gach ngang, 3-60 ky tu")
    if n in seen_names:
        err(f"ten account trung: {n}")
    seen_names[n] = i

    # EMAIL - truong khong sua duoc
    em = a.get("email")
    if not em:
        err(f"{n}: thieu 'email'")
    elif not re.fullmatch(r"[^@\s]+@[^@\s]+\.[a-z]{2,}", str(em)):
        err(f"{n}: email khong hop le: {em!r}")
    else:
        if em in seen_emails:
            err(f"{n}: email trung voi {seen_emails[em]} ({em}). "
                "Email account la DUY NHAT VINH VIEN o pham vi AWS toan cau")
        seen_emails[em] = n
        if "+" not in em.split("@")[0]:
            warn(f"{n}: email khong dung plus-addressing ({em}). "
                 "Moi account can mot email RIENG - khong plus-address thi "
                 "phai co mot hop thu that cho tung account")

    ou = a.get("ou")
    if not ou:
        err(f"{n}: thieu 'ou'")
    elif ou not in OUS:
        err(f"{n}: ou={ou!r} khong co trong cay OU. Hop le: {', '.join(sorted(OUS))}")
    elif ou == "Root":
        err(f"{n}: dat vao Root nghia la account chi con SCP o root - "
            "mat network_lock va prod_guard, ma van chay binh thuong")

    sc = a.get("scope")
    if not sc:
        err(f"{n}: thieu 'scope'")
    elif sc not in SCOPES:
        err(f"{n}: scope={sc!r} khong hop le. Hop le: {', '.join(sorted(SCOPES))}")

    env = a.get("environment")
    if not env:
        err(f"{n}: thieu 'environment'")
    elif env not in ENVS:
        err(f"{n}: environment={env!r} khong hop le. Hop le: {', '.join(sorted(ENVS))} "
            "(doc 11 muc 2 - tag policy tu choi gia tri khac)")

    for field, msg in (
        ("owner", "khong biet hoi ai khi account nay co van de"),
        ("cost_center", "hoa don cua account nay khong ve dau ca"),
        ("ticket", "mot account la cam ket dai han, khong ai duyet thi khong ai chiu"),
    ):
        if not a.get(field):
            err(f"{n}: thieu '{field}' - {msg}")

    if a.get("cost_center") and not re.fullmatch(r"CC-[0-9]{4}", str(a["cost_center"])):
        warn(f"{n}: cost_center={a['cost_center']!r} khong theo khuon CC-NNNN (doc 11)")

    # MANG
    net = a.get("network")
    if net is None:
        continue
    if not isinstance(net, dict):
        err(f"{n}: 'network' phai la mot khoi khoa/gia tri")
        continue

    cidr = net.get("vpc_cidr")
    if not cidr:
        err(f"{n}: co khoi 'network' nhung thieu 'vpc_cidr'")
        continue
    try:
        v = ipaddress.ip_network(str(cidr), strict=True)
    except ValueError as e:
        err(f"{n}: vpc_cidr khong hop le: {cidr!r} ({e})")
        continue

    if v.prefixlen > 16:
        err(f"{n}: vpc_cidr {cidr} nho hon /16. Thiet ke chia VPC thanh 4 subnet "
            "/24 (2 private + 2 tgw); /17 tro xuong khong du cho de mo rong")

    for r, ten in RESERVED:
        if v.overlaps(r):
            err(f"{n}: vpc_cidr {cidr} DAM VAO dai ha tang {r} ({ten})")

    alloc = ALLOCATED.get(a.get("ou"))
    if alloc:
        lo, hi = alloc
        first, last = int(v[0]) >> 16 & 0xFF, int(v[-1]) >> 16 & 0xFF
        in_range = (int(v[0]) >> 24) == 10 and lo <= first and last <= hi
        if not in_range:
            err(f"{n}: vpc_cidr {cidr} nam NGOAI dai cap phat cho OU {a['ou']} "
                f"(10.{lo}.0.0 - 10.{hi}.255.255). Xem bang o doc 17 muc 3")

    for other_name, other in nets:
        if v.overlaps(other):
            err(f"{n}: vpc_cidr {cidr} TRUNG voi {other_name} ({other}). "
                "Hai spoke trung dai trong mot luoi TGW thi route table khong "
                "phan biet duoc, va sua thi phai XOA VPC")
    nets.append((n, v))

    attach = net.get("attach_tgw", True)
    if not isinstance(attach, bool):
        err(f"{n}: attach_tgw phai la true hoac false")
    elif attach and a.get("ou") == "Sandbox":
        warn(f"{n}: sandbox noi vao TGW. Bang cap phat o doc 17 danh 10.60.0.0/14 "
             "cho sandbox voi ghi chu KHONG noi TGW - sandbox noi vao luoi "
             "chung la mot duong tu mot moi truong khong ai ra soat")
    elif not attach:
        warn(f"{n}: attach_tgw = false - VPC nay KHONG noi vao luoi chung. "
             "Khong co DNS tap trung, khong co VPC endpoint tap trung, va "
             "duong ra Internet phai tu lo")

    dns = net.get("attach_dns", attach if isinstance(attach, bool) else True)
    if not isinstance(dns, bool):
        err(f"{n}: attach_dns phai la true hoac false")
    elif dns and isinstance(attach, bool) and not attach:
        # Cho phep, nhung phai noi ra: dung khi VPC duoc noi bang cach
        # khac (peering). Sai thi moi ten dich vu AWS phan giai ra mot
        # dia chi khong di toi duoc, va do la mot account hong hoan
        # toan chu khong phai mot tinh nang thieu.
        warn(f"{n}: attach_dns = true nhung attach_tgw = false. Route 53 Profile tro ten "
             "dich vu AWS vao interface endpoint o security VPC (10.1.0.0/16), ma VPC nay "
             "khong co duong toi do. Moi loi goi API se phan giai ra mot dia chi KHONG DI "
             "TOI DUOC - te hon IP cong khai. Chi dat true khi VPC duoc noi bang cach khac")

########################################
# In ket qua
########################################
print()
for m in warns:
    print(f"  CANH BAO  {m}")
for m in errors:
    print(f"  LOI       {m}")

n_net = len(nets)
print()
print(f"  Catalog: {len(seen_names)} account, {n_net} co VPC noi vao luoi")

if errors:
    print(f"\n  {len(errors)} loi, {len(warns)} canh bao - SUA TRUOC KHI APPLY")
    sys.exit(1)
if warns and strict:
    print(f"\n  0 loi, {len(warns)} canh bao - --strict nen coi la that bai")
    sys.exit(1)
if warns:
    print(f"\n  Sach. {len(warns)} canh bao.")
else:
    print("\n  Sach. 0 canh bao.")

print()
print("  Buoc tiep: terraform plan")
print("             (kiem them nhung thu can AWS: OU co that khong,")
print("              email da dung o account khac chua)")
PY
